import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { ListingFilters } from '../ServerConfig';
import { Utils } from '../Utils';
import { CountlyFeature, SegmentationMap } from '../../types/Types';

export class ViewIds {
  currentViewId: string;
  previousViewId: string;
  constructor(currentViewId: string, previousViewId: string) {
    this.currentViewId = currentViewId;
    this.previousViewId = previousViewId;
  }
}

/**
 * In-memory event shape. Events are queued here then batched into a single
 * events=[...] request when the threshold is reached, the app backgrounds,
 * or an immediate-flush internal event is recorded.
 */
interface QueuedEvent {
  key: string;
  count: number;
  sum: number;
  dur: number;
  segmentation: SegmentationMap;
  timestamp: number;
  hour: number;
  dow: number;
  id: string;
  pvid: string;
  cvid: string;
  peid: string;
}

interface TimedEvent {
  startTs: number;
}

const IMMEDIATE_FLUSH_KEYS: string[] = ['[CLY]_nps', '[CLY]_survey', '[CLY]_push_action'];

/**
 * Events + timed events. Internal events (keys starting with `[CLY]_`) bypass
 * the events-consent check, they use their own feature consent instead.
 */
export class ModuleEvents extends ModuleBase {
  private core: SdkCore;
  private eventQueue: QueuedEvent[] = [];
  /**
   * Mutex guarding `flushEventQueue`. Lifecycle background fans the same
   * flush call across three modules (sessions → endSessionInternal calls
   * core.flushEvents, events.onEnterBackground calls flushEventQueue,
   * and `endSessionInternal` itself also routes through this method).
   * Without this flag two concurrent callers `slice(0, count)` the SAME
   * events before either has spliced — verified live, two identical
   * REQUEST ENQUEUED entries 1ms apart with the same 6 events. The flag
   * makes the second call a no-op; the events stay in queue and ship on
   * the next flush trigger (or via end_session's await).
   */
  private flushInProgress: boolean = false;
  private timed: Map<string, TimedEvent> = new Map<string, TimedEvent>();
  private lastEventId: string = '';
  private lastEventName: string = '';

  /** Back-pointer so events can get current/previous view IDs from Views module. */
  private viewIdProvider: () => ViewIds = (): ViewIds => new ViewIds('', '');

  /** Foreground/background tracking toggle, when set, cly_v is added to segmentation. */
  private visibilityTracking: boolean = false;
  private previousNameRecording: boolean = false;
  // Default false so events recorded BEFORE the first onEnterForeground (e.g.
  // from a background service-ability init) correctly report cly_v=0.
  private inForeground: boolean = false;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleEvents] Initialising');
    this.core = core;
  }

  public setViewIdProvider(cb: () => ViewIds): void {
    this.viewIdProvider = cb;
  }

  public enableVisibilityTracking(): void { this.visibilityTracking = true; }
  public enablePreviousNameRecording(): void { this.previousNameRecording = true; }

  public override onEnterForeground(): void { this.inForeground = true; }
  public override onEnterBackground(): void {
    this.inForeground = false;
    // Flush before going to background so we don't lose events. A rejection
    // here means the events remain in the in-memory queue for the next tick,
    // but we still log it loudly, a silent drop masks data-loss bugs.
    this.flushEventQueue().catch((err: Object) => {
      this.config.logger.e(`[ModuleEvents] onEnterBackground, flushEventQueue rejected: ${err}`);
    });
  }

  /**
   * Public event recording entry. Consent gating:
   *   - custom events require "events" consent
   *   - internal events ([CLY]_*) require their feature-specific consent ONLY
   *     (not "events") per dev guide. We enforce that here, don't trust
   *     external callers to have done it.
   */
  public async recordEvent(
    key: string,
    segmentation: SegmentationMap | null,
    count: number,
    sum: number,
    dur: number
  ): Promise<void> {
    if (this.rejectIfHalted('ModuleEvents', 'recordEvent')) return;
    await this.recordEventAt(key, segmentation, count, sum, dur, this.config.clock.nowMs());
  }

  /**
   * Record an event that already occurred at a known past timestamp. Useful
   * when an integrator buffers events themselves (e.g. while offline via a
   * 3rd-party queue) and later flushes them into Countly, the original
   * wall-clock time matters for bucketing, so we don't overwrite it with
   * "now". Non-positive timestamps fall back to the current monotonic one.
   */
  public async recordPastEvent(
    key: string,
    segmentation: SegmentationMap | null,
    count: number,
    sum: number,
    dur: number,
    timestamp: number
  ): Promise<void> {
    if (this.rejectIfHalted('ModuleEvents', 'recordPastEvent')) return;
    let ts: number = timestamp;
    if (!Number.isFinite(ts) || ts <= 0) {
      this.config.logger.w(`[ModuleEvents] recordPastEvent, timestamp must be > 0 (got ${timestamp}), falling back to current time`);
      ts = this.config.clock.nowMs();
    }
    await this.recordEventAt(key, segmentation, count, sum, dur, ts);
  }

  /**
   * Internal entry used by ModuleViews to emit `[CLY]_view` events while
   * forcing the event's `id` field to equal the view's id. Without this, view
   * start/stop events would each generate a fresh event id and the
   * dashboard's view-id chain (start.id == stop.id, next-view.pvid ==
   * previous-view.id) would break.
   */
  public async recordViewEvent(
    viewId: string,
    segmentation: SegmentationMap | null,
    dur: number
  ): Promise<void> {
    await this.recordEventAt('[CLY]_view', segmentation, 1, 0, dur, this.config.clock.nowMs(), viewId);
  }

  private async recordEventAt(
    key: string,
    segmentation: SegmentationMap | null,
    count: number,
    sum: number,
    dur: number,
    ts: number,
    forcedEventId?: string
  ): Promise<void> {
    // Defense-in-depth gate: `recordViewEvent` is public and calls this
    // path directly (bypassing the gate on `recordEvent`). Also catches
    // any future internal caller. The halt-drain path (`flushEventQueue`)
    // does NOT call this method, so the drain still works.
    if (this.rejectIfHalted('ModuleEvents', `recordEvent('${key}')`)) return;
    if (Utils.isNullOrEmpty(key)) {
      this.config.logger.w('[ModuleEvents] recordEvent, key is null/empty, omitted');
      return;
    }
    const isInternal: boolean = key.startsWith('[CLY]_');
    const requiredConsents: string[] = isInternal
      ? ModuleEvents.consentForInternalEvent(key)
      : [CountlyFeature.EVENTS];
    if (requiredConsents.length > 0) {
      // Multi-consent gate: rating events accept `starRating` OR `feedback`,
      // action events accept `clicks` OR `scrolls`.
      let granted: boolean = false;
      for (let i = 0; i < requiredConsents.length; i++) {
        if (this.core.consentModule.hasConsent(requiredConsents[i])) { granted = true; break; }
      }
      if (!granted) {
        this.config.logger.v(`[ModuleEvents] recordEvent, none of [${requiredConsents.join(',')}] consent, omitted (key=${key})`);
        return;
      }
    }
    if (count < 1) {
      this.config.logger.w('[ModuleEvents] recordEvent, count < 1, clamped to 1');
      count = 1;
    }

    // Server-config filters apply to custom events only. Internal [CLY]_*
    // events are part of the SDK's own data model, killswitching them via
    // the generic "customEventTrackingEnabled" flag or a name filter would
    // corrupt sessions/views/crashes on the dashboard. Filters MUST run on
    // the original key (not the truncated one) so integrators can configure
    // them against the keys they actually pass in.
    if (!isInternal) {
      if (!this.config.serverConfig.customEventTrackingEnabled) {
        this.config.logger.d(`[ModuleEvents] recordEvent, custom event tracking disabled by server config, dropped (key=${key})`);
        return;
      }
      if (!ListingFilters.applyEventFilter(key, this.config.serverConfig)) {
        this.config.logger.w(`[ModuleEvents] recordEvent, key='${key}' filtered out by event filter, ignored`);
        return;
      }
    }

    // Truncate custom event keys/segmentation by internal limits. Internal
    // events must pass through unmodified.
    let finalKey: string = key;
    let finalSeg: SegmentationMap = {};
    if (isInternal) {
      finalSeg = segmentation ? segmentation : {};
    } else {
      // Per-event segmentation filter keys off the ORIGINAL name too, for the
      // same reason. Run filters on the sanitised map but use `key`, not
      // `finalKey`, as the lookup.
      finalKey = Utils.truncate(key, this.config.limits.maxKeyLength);
      finalSeg = Utils.sanitizeSegmentation(
        segmentation,
        this.config.limits.maxKeyLength,
        this.config.limits.maxValueSize,
        this.config.limits.maxSegmentationValues
      );
      finalSeg = ListingFilters.applySegmentationFilter(finalSeg, this.config.serverConfig, this.config.logger);
      finalSeg = ListingFilters.applyEventSegmentationFilter(key, finalSeg, this.config.serverConfig, this.config.logger);
    }

    // Attach visibility + previous-name segmentation.
    if (this.visibilityTracking && key !== '[CLY]_view') {
      finalSeg['cly_v'] = this.inForeground ? 1 : 0;
    }
    if (this.previousNameRecording) {
      if (!isInternal) {
        finalSeg['cly_pen'] = this.lastEventName;
        const viewIds: ViewIds = this.viewIdProvider();
        finalSeg['cly_cvn'] = viewIds.currentViewId;
      }
    }

    // Before recording, save pending user profile changes so ordering is right.
    await this.core.saveUserProfileIfPending();

    const id: string = forcedEventId !== undefined ? forcedEventId : this.config.clock.generateEventId();
    const viewIds: ViewIds = this.viewIdProvider();
    const cvid: string = key === '[CLY]_view' ? '' : viewIds.currentViewId;
    const pvid: string = key === '[CLY]_view' ? viewIds.previousViewId : '';
    const peid: string = (isInternal || IMMEDIATE_FLUSH_KEYS.indexOf(key) !== -1) ? '' : this.lastEventId;

    const event: QueuedEvent = {
      key: finalKey,
      count: count,
      sum: sum,
      dur: dur,
      segmentation: finalSeg,
      timestamp: ts,
      hour: Utils.hourOf(ts),
      dow: Utils.dayOfWeek(ts),
      id: id,
      pvid: pvid,
      cvid: cvid,
      peid: peid
    };
    this.eventQueue.push(event);

    if (!isInternal) {
      this.lastEventId = id;
      this.lastEventName = finalKey;
    }

    // Public API call trace, INFO per dev guide §Log Levels ("Info: public
    // method calls"). Lets integrators confirm "yes, the event made it to the
    // event queue" without lowering minLevel to DEBUG/VERBOSE.
    // Includes count/sum/dur plus the segmentation JSON so duplicate-event
    // investigations can tell two adjacent recordEvent calls apart (e.g.
    // auto-view start vs. auto-view stop on a transition) at a glance.
    const segJson: string = segmentation !== null ? JSON.stringify(segmentation) : '{}';
    this.config.logger.i(`[ModuleEvents] recordEvent, queued key='${finalKey}' count=${count} sum=${sum} dur=${dur} segmentation=${segJson} viewId=${forcedEventId ?? '-'} queueSize=${this.eventQueue.length}`);

    // Immediate-flush internal events.
    if (IMMEDIATE_FLUSH_KEYS.indexOf(key) !== -1) {
      await this.flushEventQueue();
      return;
    }

    if (this.eventQueue.length >= this.config.eventQueueThreshold) {
      await this.flushEventQueue();
    }
  }

  public startEvent(key: string): void {
    if (this.rejectIfHalted('ModuleEvents', 'startEvent')) return;
    if (Utils.isNullOrEmpty(key)) return;
    if (this.timed.has(key)) {
      this.config.logger.w(`[ModuleEvents] startEvent, '${key}' already started, ignored`);
      return;
    }
    const ts: number = this.config.clock.nowMs();
    this.timed.set(key, { startTs: ts });
    this.config.logger.i(`[ModuleEvents] startEvent, started timer for '${key}'`);
  }

  public cancelEvent(key: string): void {
    if (this.rejectIfHalted('ModuleEvents', 'cancelEvent')) return;
    if (!this.timed.has(key)) {
      this.config.logger.w(`[ModuleEvents] cancelEvent, no timed event '${key}'`);
      return;
    }
    this.timed.delete(key);
    this.config.logger.i(`[ModuleEvents] cancelEvent, discarded timer for '${key}'`);
  }

  public async endEvent(key: string, segmentation: SegmentationMap | null, count: number, sum: number): Promise<void> {
    if (this.rejectIfHalted('ModuleEvents', 'endEvent')) return;
    const timed: TimedEvent | undefined = this.timed.get(key);
    if (!timed) {
      this.config.logger.w(`[ModuleEvents] endEvent, no timed event '${key}'`);
      return;
    }
    const durSec: number = (Date.now() - timed.startTs) / 1000;
    this.timed.delete(key);
    // Delegate to the shared recording path with the ORIGINAL start
    // timestamp (per dev guide), so hour/dow bucket on the start of the
    // span rather than the end. Sanitization, server-config event +
    // segmentation filters, consent gating, visibility/previous-name
    // tagging, peid chain, the INFO log, and threshold-flushing all
    // happen there — keeping `endEvent` aligned with `recordEvent`
    // instead of maintaining a second near-duplicate pipeline.
    await this.recordEventAt(key, segmentation, count, sum, durSec, timed.startTs);
  }

  /**
   * Drop all buffered events without flushing, used by ModuleRequestQueue's
   * `flushQueues()` to reset both queues at once. Started timed events are
   * intentionally preserved per dev guide §Queue Operations.
   */
  public clearEventQueue(): void { this.eventQueue = []; }

  /** True when the in-memory event queue has at least one buffered event. */
  public hasPendingEvents(): boolean { return this.eventQueue.length > 0; }

  public async flushEventQueue(): Promise<void> {
    if (this.eventQueue.length === 0) return;
    if (this.flushInProgress) {
      // A concurrent flush is mid-await on `requestQueue.enqueue`; the
      // splice that would remove the in-flight batch hasn't run yet, so
      // serializing here would re-batch the SAME events. Drop and let
      // the next flush trigger (next recordEvent threshold, next
      // endSession/onEnterBackground) pick up anything that's accumulated.
      this.config.logger.d(`[ModuleEvents] flushEventQueue, skipped (concurrent flush in progress, queueSize=${this.eventQueue.length})`);
      return;
    }
    this.flushInProgress = true;
    try {
      // Snapshot without mutating so an enqueue failure doesn't silently lose
      // events. Only after enqueue resolves do we drop them from the in-memory
      // queue. If enqueue throws, the events stay queued for the next trigger.
      const count: number = Math.min(this.eventQueue.length, this.config.eventQueueThreshold);
      const batch: QueuedEvent[] = this.eventQueue.slice(0, count);
      const payload: Record<string, Object>[] = batch.map((e: QueuedEvent) => ModuleEvents.serializeEvent(e));
      const params: Record<string, string> = this.core.requestBuilder.baseParams();
      params['events'] = JSON.stringify(payload);
      const body: string = Utils.buildQueryString(params);
      // DEBUG, the flush-to-request-queue handoff. Visible at the default
      // minLevel=DEBUG so integrators can see which recordEvent call triggered
      // the batch send without going to VERBOSE.
      this.config.logger.d(`[ModuleEvents] flushEventQueue, sending batch of ${count} event(s)`);
      try {
        await this.core.requestQueue.enqueue(body);
      } catch (err) {
        this.config.logger.e(`[ModuleEvents] flushEventQueue, enqueue rejected: ${err}, events remain in memory queue`);
        return;
      }
      // Successful enqueue, drop the batch. Splice on length not on identity
      // because internal events (e.g. NPS) could have been pushed during the
      // await and we want the batched-out ones, not the newcomers.
      this.eventQueue.splice(0, count);
    } finally {
      this.flushInProgress = false;
    }
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    // Clear timed events, they belonged to the previous user.
    this.timed.clear();
    this.lastEventId = '';
    this.lastEventName = '';
  }

  public override async onHalt(): Promise<void> {
    await this.flushEventQueue();
  }

  /**
   * Map a [CLY]_* internal event key to the feature consents that gate it.
   * Returns an OR-set: any single consent in the array unlocks the event.
   * Unknown internal events return `[]` (allow). Reflects the dev guide's
   * "Internal Events" consent mapping table.
   */
  private static consentForInternalEvent(key: string): string[] {
    if (key === '[CLY]_view') return [CountlyFeature.VIEWS];
    if (key === '[CLY]_nps' || key === '[CLY]_survey') return [CountlyFeature.FEEDBACK];
    // Rating + action events accept multiple consents, gives integrators
    // the flexibility to grant the narrow consent (starRating / clicks /
    // scrolls) without also having to grant the broader feedback consent.
    if (key === '[CLY]_star_rating') return [CountlyFeature.STAR_RATING, CountlyFeature.FEEDBACK];
    if (key === '[CLY]_push_action') return [CountlyFeature.PUSH];
    if (key === '[CLY]_orientation') return [CountlyFeature.USERS];
    if (key === '[CLY]_action') return [CountlyFeature.CLICKS, CountlyFeature.SCROLLS];
    return [];
  }

  private static serializeEvent(e: QueuedEvent): Record<string, Object> {
    const out: Record<string, Object> = {};
    out['key'] = e.key;
    out['count'] = e.count;
    if (e.sum !== 0) out['sum'] = e.sum;
    if (e.dur !== 0) out['dur'] = e.dur;
    if (Object.keys(e.segmentation).length > 0) out['segmentation'] = e.segmentation as Object;
    out['timestamp'] = e.timestamp;
    out['hour'] = e.hour;
    out['dow'] = e.dow;
    out['id'] = e.id;
    if (e.pvid.length > 0) out['pvid'] = e.pvid;
    if (e.cvid.length > 0) out['cvid'] = e.cvid;
    if (e.peid.length > 0) out['peid'] = e.peid;
    return out;
  }
}
