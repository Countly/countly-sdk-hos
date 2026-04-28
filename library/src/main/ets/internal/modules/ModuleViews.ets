import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { ModuleEvents, ViewIds } from './ModuleEvents';
import { FirstViewFlagHost } from './ModuleSessions';
import { Utils } from '../Utils';
import { ConsentChangeSource, CountlyFeature, SegmentationMap } from '../../types/Types';

class ViewsModuleFirstViewFlagHost implements FirstViewFlagHost {
  private owner: ModuleViews;
  constructor(owner: ModuleViews) {
    this.owner = owner;
  }
  reset(): void {
    this.owner.markFirstViewInSession();
  }
}

interface ActiveView {
  id: string;
  name: string;
  autoStopped: boolean;
  startTsSec: number;  // 0 when paused
  accumulatedSegmentation: SegmentationMap;
  willStartAgain: boolean;
}

const RESERVED_VIEW_KEYS: string[] = ['name', 'visit', 'start', 'segment', 'bounce', 'exit', 'view', 'domain', 'dur'];

/**
 * Views module. Three view flavors coexist:
 *   - Auto-stopped: only one can be active; starting a new one stops the prev.
 *   - Manual: many can be active at once, explicit stopView needed.
 *   - Paused: still in the map but not accumulating duration.
 *
 * All view lifecycle produces `[CLY]_view` internal events, gated on `views`
 * consent (enforced per call below because the Events module bypasses the
 * `events` consent check for internal events).
 */
export class ModuleViews extends ModuleBase {
  private core: SdkCore;
  private events: ModuleEvents;
  private activeViews: Map<string, ActiveView> = new Map<string, ActiveView>();
  private currentAutoStoppedId: string = '';
  private currentViewId: string = '';
  private previousViewId: string = '';
  private firstViewInSession: boolean = true;
  private globalSegmentation: SegmentationMap = {};
  // Last orientation emitted so we can dedupe redundant [CLY]_orientation
  // events. Empty string means "nothing sent yet" so the first call always
  // gets through (matches Android, where currentOrientation defaults to
  // Configuration.ORIENTATION_UNDEFINED/0 and any real value differs).
  private lastOrientationMode: string = '';

  constructor(config: InternalConfig, core: SdkCore, events: ModuleEvents) {
    super(config);
    this.config.logger.v('[ModuleViews] Initialising');
    this.core = core;
    this.events = events;
    this.globalSegmentation = Utils.mergeMaps({}, config.globalViewSegmentation);
  }

  public getIds(): ViewIds {
    return new ViewIds(this.currentViewId, this.previousViewId);
  }

  public getFirstViewFlagHost(): FirstViewFlagHost {
    return new ViewsModuleFirstViewFlagHost(this);
  }

  public markFirstViewInSession(): void {
    this.firstViewInSession = true;
  }

  public async startAutoStoppedView(name: string, segmentation: SegmentationMap | null): Promise<string | null> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) return null;
    if (!this.config.serverConfig.viewTrackingEnabled) return null;
    if (Utils.isNullOrEmpty(name)) {
      this.config.logger.w('[ModuleViews] startAutoStoppedView, empty name — omitted');
      return null;
    }
    if (this.currentAutoStoppedId.length > 0) {
      await this.stopViewWithID(this.currentAutoStoppedId, null);
    }
    const id: string = await this.startInternal(name, segmentation, true);
    this.currentAutoStoppedId = id;
    return id;
  }

  public async startView(name: string, segmentation: SegmentationMap | null): Promise<string | null> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) return null;
    if (!this.config.serverConfig.viewTrackingEnabled) return null;
    if (Utils.isNullOrEmpty(name)) {
      this.config.logger.w('[ModuleViews] startView, empty name — omitted');
      return null;
    }
    return this.startInternal(name, segmentation, false);
  }

  public async stopViewWithName(name: string, segmentation: SegmentationMap | null): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) return;
    if (!this.config.serverConfig.viewTrackingEnabled) return;
    // If multiple, stop the latest started.
    const ids: string[] = this.activeViewIds();
    for (let i = ids.length - 1; i >= 0; i--) {
      const v: ActiveView | undefined = this.activeViews.get(ids[i]);
      if (v && v.name === name) {
        await this.stopViewWithID(ids[i], segmentation);
        return;
      }
    }
    this.config.logger.w(`[ModuleViews] stopViewWithName, no active view '${name}'`);
  }

  public async stopViewWithID(id: string, segmentation: SegmentationMap | null): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) return;
    if (!this.config.serverConfig.viewTrackingEnabled) return;
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) {
      this.config.logger.w(`[ModuleViews] stopViewWithID, no active view id '${id}'`);
      return;
    }
    const durSec: number = view.startTsSec === 0 ? 0 : Math.round(Date.now() / 1000) - view.startTsSec;
    const seg: SegmentationMap = Utils.mergeMaps(view.accumulatedSegmentation, segmentation ? segmentation : {});
    const mergedGlobal: SegmentationMap = Utils.mergeMaps(this.globalSegmentation, seg);
    const finalSeg: SegmentationMap = this.stripReservedAndSanitize(mergedGlobal);
    finalSeg['name'] = view.name;

    this.activeViews.delete(id);
    if (this.currentAutoStoppedId === id) this.currentAutoStoppedId = '';

    // Force the stop event's `id` field to the view id, so start/stop pairs
    // share the same id on the wire — Android-parity, the dashboard relies on
    // it to attribute the duration to the right view.
    await this.events.recordViewEvent(id, finalSeg, durSec);
  }

  public pauseViewWithID(id: string): void {
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) return;
    if (view.startTsSec === 0) return;
    view.startTsSec = 0;
  }

  public resumeViewWithID(id: string): void {
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) return;
    if (view.startTsSec !== 0) return;
    view.startTsSec = Math.round(Date.now() / 1000);
  }

  public async stopAllViews(segmentation: SegmentationMap | null): Promise<void> {
    const ids: string[] = this.activeViewIds();
    for (let i = 0; i < ids.length; i++) {
      await this.stopViewWithID(ids[i], segmentation);
    }
  }

  public addSegmentationToViewWithID(id: string, seg: SegmentationMap): void {
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) return;
    view.accumulatedSegmentation = Utils.mergeMaps(view.accumulatedSegmentation, seg);
  }

  // Snapshot all active view IDs. We materialize an array rather than iterating
  // the Map directly so callers that mutate during iteration (stopView deletes
  // the entry) don't invalidate the iterator.
  private activeViewIds(): string[] {
    const ids: string[] = [];
    this.activeViews.forEach((_v: ActiveView, k: string) => { ids.push(k); });
    return ids;
  }

  public addSegmentationToViewWithName(name: string, seg: SegmentationMap): void {
    const ids: string[] = this.activeViewIds();
    for (let i = ids.length - 1; i >= 0; i--) {
      const v: ActiveView | undefined = this.activeViews.get(ids[i]);
      if (v && v.name === name) {
        this.addSegmentationToViewWithID(ids[i], seg);
        return;
      }
    }
  }

  public setGlobalViewSegmentation(seg: SegmentationMap): void {
    this.globalSegmentation = Utils.mergeMaps({}, seg);
  }

  public updateGlobalViewSegmentation(seg: SegmentationMap): void {
    this.globalSegmentation = Utils.mergeMaps(this.globalSegmentation, seg);
  }

  /**
   * Record an orientation change. Auto-driven by `LifecycleObserver` via
   * `applicationContext.on('environment', ...)` when
   * `trackOrientationChanges` is on (default true) — see
   * `CountlyInstance.handleConfigurationUpdated`. Integrators can also
   * call this directly for manual control or in test harnesses.
   *
   * Accepts `'portrait'` or `'landscape'`. Emits a `[CLY]_orientation`
   * internal event gated on the `users` feature consent. Dedupes
   * consecutive identical values so rapid redundant calls (e.g. a
   * config-update fired with no actual orientation change) don't inflate
   * the event queue.
   */
  public async updateOrientation(mode: string): Promise<void> {
    if (!this.config.trackOrientationChanges) {
      this.config.logger.v('[ModuleViews] updateOrientation, trackOrientationChanges disabled — ignored');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.USERS)) {
      this.config.logger.v('[ModuleViews] updateOrientation, no users consent — ignored');
      return;
    }
    const normalized: string = mode === 'portrait' || mode === 'landscape' ? mode : '';
    if (normalized === '') {
      this.config.logger.w(`[ModuleViews] updateOrientation, unsupported mode '${mode}' — expected 'portrait' or 'landscape'`);
      return;
    }
    if (normalized === this.lastOrientationMode) {
      this.config.logger.d(`[ModuleViews] updateOrientation, unchanged (${normalized}) — skipped`);
      return;
    }
    this.lastOrientationMode = normalized;
    const seg: SegmentationMap = { 'mode': normalized };
    await this.events.recordEvent('[CLY]_orientation', seg, 1, 0, 0);
  }

  public override async onConsentChanged(_added: string[], removed: string[], _source: ConsentChangeSource): Promise<void> {
    // Clear active views when VIEWS is revoked. Also clear when SESSIONS is
    // revoked: views are session-bound per dev guide — a view without a
    // session on the server is an orphan and would inflate dashboards.
    const viewsRevoked: boolean = removed.indexOf(CountlyFeature.VIEWS) !== -1;
    const sessionsRevoked: boolean = removed.indexOf(CountlyFeature.SESSIONS) !== -1;
    if (viewsRevoked || sessionsRevoked) {
      const reason: string = viewsRevoked ? 'views' : 'sessions';
      const dropped: number = this.activeViews.size;
      this.activeViews.clear();
      this.currentAutoStoppedId = '';
      // Clear view-id context so subsequent non-view events don't carry a
      // cvid pointing at a view that was never closed on the server.
      this.currentViewId = '';
      this.previousViewId = '';
      this.firstViewInSession = true;
      if (dropped > 0) {
        this.config.logger.i(`[ModuleViews] onConsentChanged, ${reason} consent revoked — dropped ${dropped} active view(s) without final event`);
      }
    }
    // Reset orientation dedupe when USERS consent is revoked — otherwise the
    // first orientation after re-grant would be suppressed by the stale
    // lastOrientationMode, leaving the server without a baseline value.
    if (removed.indexOf(CountlyFeature.USERS) !== -1) {
      this.lastOrientationMode = '';
    }
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    // Device id switched without merge → new user. Drop the dedupe so the
    // new user's first orientation event always fires.
    this.lastOrientationMode = '';
  }

  public override onEnterBackground(): void {
    // Capture the foreground duration slice so the dashboard doesn't lose it,
    // then mark the view paused. On foreground we resume without emitting a
    // `visit=1` (which would double-count a "new visit"). Background time is
    // NOT counted toward view duration.
    const ids: string[] = this.activeViewIds();
    const nowSec: number = Math.round(Date.now() / 1000);
    for (let i = 0; i < ids.length; i++) {
      const view: ActiveView | undefined = this.activeViews.get(ids[i]);
      if (!view) continue;
      view.willStartAgain = !this.config.disableViewRestartForManual || view.autoStopped;
      if (view.willStartAgain && view.startTsSec !== 0) {
        const sliceSec: number = nowSec - view.startTsSec;
        if (sliceSec > 0) {
          // Fire-and-forget the background slice — a rejection here mustn't
          // block the lifecycle callback. The error is logged instead.
          const seg: SegmentationMap = this.stripReservedAndSanitize(
            Utils.mergeMaps(this.globalSegmentation, view.accumulatedSegmentation)
          );
          seg['name'] = view.name;
          // Slice event is the same view continuing — keep its id stable.
          this.events.recordViewEvent(ids[i], seg, sliceSec).catch((err: Object) => {
            this.config.logger.e(`[ModuleViews] onEnterBackground, slice event rejected: ${err}`);
          });
        }
        // Pause — resume will update startTsSec on foreground.
        view.startTsSec = 0;
      }
    }
  }

  public override onEnterForeground(): void {
    // Restart any "willStartAgain" views: reset startTsSec so a subsequent
    // stopView measures only the new foreground slice.
    const ids: string[] = this.activeViewIds();
    for (let i = 0; i < ids.length; i++) {
      const view: ActiveView | undefined = this.activeViews.get(ids[i]);
      if (view && view.willStartAgain) {
        view.startTsSec = Math.round(Date.now() / 1000);
        view.willStartAgain = false;
      }
    }
  }

  private async startInternal(name: string, segmentation: SegmentationMap | null, autoStopped: boolean): Promise<string> {
    const id: string = Utils.generateEventId();
    this.previousViewId = this.currentViewId;
    this.currentViewId = id;

    const seg: SegmentationMap = segmentation ? segmentation : {};
    const mergedGlobal: SegmentationMap = Utils.mergeMaps(this.globalSegmentation, seg);
    const finalSeg: SegmentationMap = this.stripReservedAndSanitize(mergedGlobal);
    finalSeg['name'] = Utils.truncate(name, this.config.limits.maxKeyLength);
    finalSeg['segment'] = 'HarmonyOS';
    finalSeg['visit'] = '1';
    if (this.firstViewInSession) {
      finalSeg['start'] = '1';
      this.firstViewInSession = false;
    }

    this.activeViews.set(id, {
      id: id,
      name: name,
      autoStopped: autoStopped,
      startTsSec: Math.round(Date.now() / 1000),
      accumulatedSegmentation: {},
      willStartAgain: false
    });

    // Force the start event's `id` field to the freshly minted view id so the
    // wire format mirrors Android: subsequent stop events and the next view's
    // pvid resolve against this same id.
    await this.events.recordViewEvent(id, finalSeg, 0);
    return id;
  }

  /**
   * Drops any segmentation keys that would collide with reserved view fields
   * ("name", "visit", "start", etc.) before merging, so custom input can't
   * overwrite SDK-owned values.
   */
  private stripReservedAndSanitize(input: SegmentationMap): SegmentationMap {
    const sanitized: SegmentationMap = Utils.sanitizeSegmentation(
      input,
      this.config.limits.maxKeyLength,
      this.config.limits.maxValueSize,
      this.config.limits.maxSegmentationValues
    );
    // ArkTS bans `delete`, so rebuild without reserved keys instead of in-place
    // removal. The filtered copy is still a plain Record<string, ...>.
    const cleaned: SegmentationMap = {};
    const keys: string[] = Object.keys(sanitized);
    for (let i = 0; i < keys.length; i++) {
      if (RESERVED_VIEW_KEYS.indexOf(keys[i]) === -1) {
        cleaned[keys[i]] = sanitized[keys[i]];
      }
    }
    return cleaned;
  }
}
