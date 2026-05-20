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

/**
 * View state captured at `onEnterBackground` for replay at
 * `onEnterForeground`. Keeps name, kind (auto-stopped vs manual), and
 * the most recently accumulated segmentation so the restarted view
 * carries the integrator's intent forward into the new session.
 * ArkTS strict mode bans untyped object literals so a named class is
 * the idiomatic shape.
 */
class ViewRestartSnapshot {
  public name: string;
  public autoStopped: boolean;
  public segmentation: SegmentationMap;
  constructor(name: string, autoStopped: boolean, segmentation: SegmentationMap) {
    this.name = name;
    this.autoStopped = autoStopped;
    this.segmentation = segmentation;
  }
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
  /**
   * Snapshots of every active view captured at `onEnterBackground` so
   * `onEnterForeground` can restart each one with a fresh `visit:1`
   * event. Both auto-stopped and manual views are restarted, the
   * integrator's lifecycle intent ("I started this view") carries
   * across bg/fg cycles. Empty array = nothing to restart.
   */
  private restartOnForeground: ViewRestartSnapshot[] = [];
  private currentViewId: string = '';
  private previousViewId: string = '';
  private firstViewInSession: boolean = true;
  private globalSegmentation: SegmentationMap = {};
  // Last orientation emitted so we can dedupe redundant [CLY]_orientation
  // events. Empty string means "nothing sent yet" so the first call always
  // gets through.
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
    if (this.rejectIfHalted('ModuleViews', 'startAutoStoppedView')) return null;
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) {
      this.config.logger.w(`[ModuleViews] startAutoStoppedView, dropped, no VIEWS consent (name=${name})`);
      return null;
    }
    if (!this.config.serverConfig.viewTrackingEnabled) {
      this.config.logger.w(`[ModuleViews] startAutoStoppedView, dropped, view tracking disabled by server config (name=${name})`);
      return null;
    }
    if (Utils.isNullOrEmpty(name)) {
      this.config.logger.w('[ModuleViews] startAutoStoppedView, empty name, omitted');
      return null;
    }
    if (this.currentAutoStoppedId.length > 0) {
      const current: ActiveView | undefined = this.activeViews.get(this.currentAutoStoppedId);
      if (current !== undefined && current.name === name) {
        // Same auto-stopped view requested twice in a row, no-op so we
        // don't emit a phantom stop+start pair. This guards two scenarios:
        //   1. `onEnterForeground` restarted view `name`, then the
        //      platform's `onAbilityForeground` fired
        //      `startAutoStoppedView(name)` for the host UIAbility (same
        //      name). The integrator's restart should win, the platform's
        //      duplicate call is a no-op.
        //   2. The platform fires `onAbilityForeground` twice for the
        //      same ability (rare but possible on focus-change
        //      sequences). Second call no-ops.
        this.config.logger.d(`[ModuleViews] startAutoStoppedView, '${name}' already the current auto-stopped view, no-op`);
        return this.currentAutoStoppedId;
      }
      await this.stopViewWithID(this.currentAutoStoppedId, null);
    }
    const id: string = await this.startInternal(name, segmentation, true);
    this.currentAutoStoppedId = id;
    return id;
  }

  public async startView(name: string, segmentation: SegmentationMap | null): Promise<string | null> {
    if (this.rejectIfHalted('ModuleViews', 'startView')) return null;
    if (!this.core.consentModule.hasConsent(CountlyFeature.VIEWS)) {
      this.config.logger.w(`[ModuleViews] startView, dropped, no VIEWS consent (name=${name})`);
      return null;
    }
    if (!this.config.serverConfig.viewTrackingEnabled) {
      this.config.logger.w(`[ModuleViews] startView, dropped, view tracking disabled by server config (name=${name})`);
      return null;
    }
    if (Utils.isNullOrEmpty(name)) {
      this.config.logger.w('[ModuleViews] startView, empty name, omitted');
      return null;
    }
    return this.startInternal(name, segmentation, false);
  }

  public async stopViewWithName(name: string, segmentation: SegmentationMap | null): Promise<void> {
    if (this.rejectIfHalted('ModuleViews', 'stopViewWithName')) return;
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
    if (this.rejectIfHalted('ModuleViews', 'stopViewWithID')) return;
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
    // share the same id on the wire, the dashboard relies on it to
    // attribute the duration to the right view.
    await this.events.recordViewEvent(id, finalSeg, durSec);
  }

  public pauseViewWithID(id: string): void {
    if (this.rejectIfHalted('ModuleViews', 'pauseViewWithID')) return;
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) return;
    if (view.startTsSec === 0) return;
    view.startTsSec = 0;
  }

  public resumeViewWithID(id: string): void {
    if (this.rejectIfHalted('ModuleViews', 'resumeViewWithID')) return;
    const view: ActiveView | undefined = this.activeViews.get(id);
    if (!view) return;
    if (view.startTsSec !== 0) return;
    view.startTsSec = Math.round(Date.now() / 1000);
  }

  public async stopAllViews(segmentation: SegmentationMap | null): Promise<void> {
    if (this.rejectIfHalted('ModuleViews', 'stopAllViews')) return;
    const ids: string[] = this.activeViewIds();
    for (let i = 0; i < ids.length; i++) {
      await this.stopViewWithID(ids[i], segmentation);
    }
  }

  public addSegmentationToViewWithID(id: string, seg: SegmentationMap): void {
    if (this.rejectIfHalted('ModuleViews', 'addSegmentationToViewWithID')) return;
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
    if (this.rejectIfHalted('ModuleViews', 'addSegmentationToViewWithName')) return;
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
    if (this.rejectIfHalted('ModuleViews', 'setGlobalViewSegmentation')) return;
    this.globalSegmentation = Utils.mergeMaps({}, seg);
  }

  public updateGlobalViewSegmentation(seg: SegmentationMap): void {
    if (this.rejectIfHalted('ModuleViews', 'updateGlobalViewSegmentation')) return;
    this.globalSegmentation = Utils.mergeMaps(this.globalSegmentation, seg);
  }

  /**
   * Record an orientation change. Auto-driven by `LifecycleObserver` via
   * `applicationContext.on('environment', ...)` when
   * `trackOrientationChanges` is on (default true), see
   * `CountlyInstance.handleConfigurationUpdated`. Integrators can also
   * call this directly for manual control or in test harnesses.
   *
   * Accepts `'portrait'` or `'landscape'`. Emits a `[CLY]_orientation`
   * internal event gated on the `users` feature consent. Dedupes
   * consecutive identical values so rapid redundant calls (e.g. a
   * config-update fired with no actual orientation change) don't inflate
   * the event queue.
   *
   * `forceSend=true` bypasses the dedupe, used at session boundaries so
   * every begin_session emits a fresh orientation baseline. Dashboards
   * always see the orientation that was current when the session started,
   * even if the device hasn't rotated since the last session. The
   * default-false matches the config-update path which should keep deduping.
   */
  public async updateOrientation(mode: string, forceSend: boolean = false): Promise<void> {
    if (this.rejectIfHalted('ModuleViews', 'updateOrientation')) return;
    if (!this.config.trackOrientationChanges) {
      this.config.logger.v('[ModuleViews] updateOrientation, trackOrientationChanges disabled, ignored');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.USERS)) {
      this.config.logger.v('[ModuleViews] updateOrientation, no users consent, ignored');
      return;
    }
    const normalized: string = mode === 'portrait' || mode === 'landscape' ? mode : '';
    if (normalized === '') {
      this.config.logger.w(`[ModuleViews] updateOrientation, unsupported mode '${mode}', expected 'portrait' or 'landscape'`);
      return;
    }
    if (!forceSend && normalized === this.lastOrientationMode) {
      this.config.logger.d(`[ModuleViews] updateOrientation, unchanged (${normalized}), skipped`);
      return;
    }
    this.lastOrientationMode = normalized;
    const seg: SegmentationMap = { 'mode': normalized };
    await this.events.recordEvent('[CLY]_orientation', seg, 1, 0, 0);
  }

  public override async onConsentChanged(_added: string[], removed: string[], _source: ConsentChangeSource): Promise<void> {
    // Clear active views when VIEWS is revoked. Also clear when SESSIONS is
    // revoked: views are session-bound per dev guide, a view without a
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
        this.config.logger.i(`[ModuleViews] onConsentChanged, ${reason} consent revoked, dropped ${dropped} active view(s) without final event`);
      }
    }
    // Reset orientation dedupe when USERS consent is revoked, otherwise the
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
    // Mirrors Android's `(autoViewTracker || restartManualViews)` gate:
    //   - `autoViewTracker` = `config.automaticViewTracking` (whether
    //     auto view tracking is enabled at config level).
    //   - `restartManualViews` = `!config.disableViewRestartForManual`
    //     (whether `startView`-started views participate in the
    //     bg→stop / fg→restart cycle).
    // If neither is enabled the integrator manages everything manually,
    // bg/fg is a no-op.
    //
    // Per-view participation within the snapshot:
    //   - Auto-stopped views (`view.autoStopped=true`, started via
    //     `startAutoStoppedView`, either platform-driven from
    //     `onAbilityForeground` or integrator-driven for a named view
    //     like 'Home'): always participate when the gate is open.
    //     `currentAutoStoppedId` tracks the single-active invariant.
    //   - Manual views (`view.autoStopped=false`, started via
    //     `startView`): participate ONLY if `restartManualViews=true`.
    //     With `disableViewRestartForManual=true` they're left
    //     completely alone (their timing accumulates across bg/fg).
    const restartManualViews: boolean = !this.config.disableViewRestartForManual;
    const autoViewTracker: boolean = this.config.automaticViewTracking;
    if (!autoViewTracker && !restartManualViews) return;

    const ids: string[] = this.activeViewIds();
    const snapshots: ViewRestartSnapshot[] = [];
    const idsToStop: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const view: ActiveView | undefined = this.activeViews.get(ids[i]);
      if (view === undefined) continue;
      // Manual views skip the snapshot when disabled.
      if (!view.autoStopped && !restartManualViews) continue;
      // Paused views (startTsSec=0) are skipped entirely, they aren't
      // accumulating duration so there's nothing to flush, and emitting
      // a stop+restart would change their integrator-controlled state.
      // The view stays in `activeViews` so the integrator can resume it
      // explicitly later.
      if (view.startTsSec === 0) continue;
      // Copy the accumulated segmentation, the original map is owned by
      // the ActiveView and would be mutated/reset when we restart.
      const segCopy: SegmentationMap = Utils.cloneSegmentationMap(view.accumulatedSegmentation);
      snapshots.push(new ViewRestartSnapshot(view.name, view.autoStopped, segCopy));
      idsToStop.push(ids[i]);
    }
    this.restartOnForeground = snapshots;
    // Collected first so the in-loop `activeViews` mutations from
    // `stopViewWithID` don't trip the iteration.
    for (let i = 0; i < idsToStop.length; i++) {
      this.stopViewWithID(idsToStop[i], null).catch((err: Object) => {
        this.config.logger.e(`[ModuleViews] onEnterBackground, view stop rejected: ${err}`);
      });
    }
  }

  public override onEnterForeground(): void {
    // Restart every view that was active at background time. Order
    // matches the snapshot order from background so any integrator that
    // relies on view-id chain (`pvid`) gets the same sequence. Auto-
    // stopped views use `startAutoStoppedView` so the single-active
    // invariant + same-name dedup with platform `onAbilityForeground`
    // both keep working; manual views use `startView`.
    const snapshots: ViewRestartSnapshot[] = this.restartOnForeground;
    if (snapshots.length === 0) return;
    this.restartOnForeground = [];
    for (let i = 0; i < snapshots.length; i++) {
      const snap: ViewRestartSnapshot = snapshots[i];
      const seg: SegmentationMap = snap.segmentation;
      const restarter: Promise<string | null> = snap.autoStopped
        ? this.startAutoStoppedView(snap.name, seg)
        : this.startView(snap.name, seg);
      restarter.catch((err: Object) => {
        this.config.logger.e(`[ModuleViews] onEnterForeground, restart of '${snap.name}' (autoStopped=${snap.autoStopped}) rejected: ${err}`);
      });
    }
  }

  private async startInternal(name: string, segmentation: SegmentationMap | null, autoStopped: boolean): Promise<string> {
    const id: string = this.config.clock.generateEventId();
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

    // Force the start event's `id` field to the freshly minted view id so
    // subsequent stop events and the next view's pvid resolve against this
    // same id.
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
