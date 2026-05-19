import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { ConsentChangeSource, CountlyFeatureNames } from '../../types/Types';
import { Utils } from '../Utils';

class ConsentDiff {
  added: string[];
  removed: string[];
  constructor(added: string[], removed: string[]) {
    this.added = added;
    this.removed = removed;
  }
}

/**
 * Central authority for consent. State is in-memory only (host app is
 * responsible for persistence) per the dev guide. Feature groups let hosts
 * bulk-toggle related consents.
 */
export class ModuleConsent extends ModuleBase {
  private core: SdkCore;
  private requiresConsent: boolean = false;
  private consent: Record<string, boolean> = {};
  private featureGroups: Record<string, string[]> = {};
  // `null` = no timer scheduled. We can't use 0 as a sentinel because HMOS's
  // setTimeout may legitimately return 0 as the first timer id of the process,
  // causing a collision with "no timer scheduled", manifests as the
  // init-time `flushInitialConsentIfPending` no-op'ing and the consent
  // snapshot deferring to the 1-second coalesce timer instead of shipping
  // before begin_session. Browsers and Node return positive ids so the older
  // `=== 0` sentinel was idiomatic but not portable.
  private pendingCoalesceTimer: number | null = null;
  /**
   * True when the constructor flipped on all initial consents (i.e.
   * `requiresConsent && initialConsentAll`) and the matching server
   * snapshot still needs to be shipped. `CountlyInstance.init()` calls
   * `flushInitialConsentIfPending()` AFTER `deviceIdModule.resolveInitial()`
   * to ship it once `device_id` is actually known. Using a flag instead of
   * a 1s `setTimeout` avoids a race where the timer fires before
   * `resolveInitial()` finishes on slow storage, emitting a `consent=`
   * request with `device_id=` (empty) that the server rejects with 400
   * "Missing parameter device_id".
   */
  private initialSnapshotPending: boolean = false;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleConsent] Initialising');
    this.core = core;
    this.requiresConsent = config.requiresConsent;
    for (let i = 0; i < CountlyFeatureNames.length; i++) {
      this.consent[CountlyFeatureNames[i]] = !this.requiresConsent;
    }
    if (this.requiresConsent && config.initialConsentAll) {
      // emit=false skips the will/did-change module dispatch, at construction
      // time other modules aren't wired into core yet, so dispatching their
      // hooks would NPE. We mark the snapshot pending so the explicit
      // `flushInitialConsentIfPending()` call from `CountlyInstance.init()`
      // ships it AFTER `deviceIdModule.resolveInitial()` has populated the
      // device id. Do NOT use the 1s `scheduleConsentRequest` coalesce
      // timer here, on slow storage init it can fire before the device id
      // resolves and emit a request with `device_id=` empty (server 400s).
      this.giveConsentAllInternal(false).catch((err: Object) => {
        this.config.logger.e(`[ModuleConsent] constructor giveConsentAllInternal rejected: ${err}`);
      });
      this.initialSnapshotPending = true;
    }
  }

  public hasConsent(feature: string): boolean {
    if (!this.requiresConsent) return true;
    if (this.featureGroups[feature]) {
      const features: string[] = this.featureGroups[feature];
      for (let i = 0; i < features.length; i++) {
        if (!this.consent[features[i]]) return false;
      }
      return true;
    }
    return this.consent[feature] === true;
  }

  public giveConsent(features: string[]): void {
    if (this.rejectIfHalted('ModuleConsent', 'giveConsent')) return;
    if (!this.requiresConsent) {
      this.config.logger.v('[ModuleConsent] giveConsent, requiresConsent is false, ignored');
      return;
    }
    // Fire-and-log: callers (public API) are synchronous; we still want any
    // rejection surfaced via the logger rather than an unhandled rejection.
    void this.giveConsentInternal(features, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] giveConsent chain rejected: ${err}`);
    });
  }

  public removeConsent(features: string[]): void {
    if (this.rejectIfHalted('ModuleConsent', 'removeConsent')) return;
    if (!this.requiresConsent) {
      this.config.logger.v('[ModuleConsent] removeConsent, requiresConsent is false, ignored');
      return;
    }
    void this.setConsentInternal(features, false, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] removeConsent chain rejected: ${err}`);
    });
  }

  public giveConsentAll(): void {
    if (this.rejectIfHalted('ModuleConsent', 'giveConsentAll')) return;
    if (this.config.consentLockedPostUnknown) {
      // Post-UCM-revoke lock: the user said no during unknown consent
      // resolution, and runtime consent is now sealed. The only way to
      // re-enable consent is to re-init with a fresh CountlyConfig.
      this.config.logger.w('[ModuleConsent] giveConsentAll, consent is set per init, runtime grant ignored (re-init to change)');
      return;
    }
    if (!this.requiresConsent) return;
    // Unknown consent mode resolves here: the buffered queue stays in the
    // request queue and is shipped when the queue resumes. We skip the
    // normal consent-snapshot path because every feature was already
    // internally granted at init, the init-time snapshot sitting in the
    // buffered queue already reflects the post-grant state.
    if (this.config.unknownConsentMode) {
      void this.core.resolveUnknownConsent(true).catch((err: Object) => {
        this.config.logger.e(`[ModuleConsent] giveConsentAll unknown-mode resolve rejected: ${err}`);
      });
      return;
    }
    void this.giveConsentAllInternal(true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] giveConsentAll chain rejected: ${err}`);
    });
  }

  public removeConsentAll(): void {
    if (this.rejectIfHalted('ModuleConsent', 'removeConsentAll')) return;
    if (this.config.consentLockedPostUnknown) {
      // Post-UCM-revoke lock: already revoked, runtime mutations sealed.
      this.config.logger.w('[ModuleConsent] removeConsentAll, consent is set per init, runtime mutation ignored (re-init to change)');
      return;
    }
    if (!this.requiresConsent) return;
    // Unknown consent mode resolves here: clear buffered data, send a
    // revocation snapshot, lock further runtime consent changes, but keep
    // the instance running so the integrator can keep using the SDK in
    // "consent denied" state (matches normal-flow behavior post-revoke).
    if (this.config.unknownConsentMode) {
      void this.core.resolveUnknownConsent(false).catch((err: Object) => {
        this.config.logger.e(`[ModuleConsent] removeConsentAll unknown-mode resolve rejected: ${err}`);
      });
      return;
    }
    const all: string[] = CountlyFeatureNames.slice();
    void this.setConsentInternal(all, false, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] removeConsentAll chain rejected: ${err}`);
    });
  }

  public setConsent(features: string[], given: boolean): void {
    if (this.rejectIfHalted('ModuleConsent', 'setConsent')) return;
    if (given) this.giveConsent(features);
    else this.removeConsent(features);
  }

  public checkAllConsent(): boolean {
    if (!this.requiresConsent) return true;
    for (let i = 0; i < CountlyFeatureNames.length; i++) {
      if (!this.consent[CountlyFeatureNames[i]]) return false;
    }
    return true;
  }

  /** True when at least one feature has consent. Used by `addDirectRequest` to
   *  drop custom requests when the integrator hasn't granted anything at all. */
  public hasAnyConsent(): boolean {
    if (!this.requiresConsent) return true;
    for (let i = 0; i < CountlyFeatureNames.length; i++) {
      if (this.consent[CountlyFeatureNames[i]]) return true;
    }
    return false;
  }

  public createFeatureGroup(groupName: string, features: string[]): void {
    if (this.rejectIfHalted('ModuleConsent', 'createFeatureGroup')) return;
    this.featureGroups[groupName] = features.slice();
  }

  public setConsentFeatureGroup(groupName: string, given: boolean): void {
    if (this.rejectIfHalted('ModuleConsent', 'setConsentFeatureGroup')) return;
    const features: string[] | undefined = this.featureGroups[groupName];
    if (!features) {
      this.config.logger.w(`[ModuleConsent] setConsentFeatureGroup, unknown group '${groupName}'`);
      return;
    }
    this.setConsent(features, given);
  }

  /**
   * Reset consents when device ID changes without merge. Does NOT schedule a
   * consent snapshot request, the source tag documents that this flow
   * belongs to the device-ID change path, not a developer decision.
   */
  public async resetForDeviceIdChangeNotMerged(): Promise<void> {
    const had: string[] = [];
    const keys: string[] = Object.keys(this.consent);
    for (let i = 0; i < keys.length; i++) {
      if (this.consent[keys[i]]) had.push(keys[i]);
    }
    if (had.length === 0) return;
    await this.core.notifyConsentWillChange([], had, ConsentChangeSource.DeviceIDChangedNotMerged);
    for (let i = 0; i < had.length; i++) this.consent[had[i]] = false;
    await this.core.notifyConsentDidChange([], had, ConsentChangeSource.DeviceIDChangedNotMerged);
  }

  private giveConsentAllInternal(emit: boolean): Promise<void> {
    return this.setConsentInternal(CountlyFeatureNames.slice(), true, emit);
  }

  private giveConsentInternal(features: string[], emit: boolean): Promise<void> {
    return this.setConsentInternal(features, true, emit);
  }

  /**
   * Three-phase consent change:
   *   1. compute the diff
   *   2. apply the diff synchronously so a sync `hasConsent` call right after
   *      `giveConsent` returns sees the new value
   *   3. await notifyConsentWillChange so modules can flush in-flight work
   *   4. await notifyConsentDidChange; schedule the coalesced server snapshot
   *
   * willChange listeners receive the diff (added/removed lists) and the
   * source, they should drive their cleanup off those parameters, not by
   * re-querying `hasConsent` for the modified features.
   */
  private async setConsentInternal(features: string[], given: boolean, emit: boolean): Promise<void> {
    const diff: ConsentDiff = this.computeDiff(features, given);
    if (diff.added.length === 0 && diff.removed.length === 0) return;

    // Apply the diff synchronously (before any await) so the public
    // giveConsent/removeConsent contract is "state is updated by the time the
    // call returns", anything else makes synchronous getConsent unreliable.
    for (let i = 0; i < diff.added.length; i++) this.consent[diff.added[i]] = true;
    for (let i = 0; i < diff.removed.length; i++) this.consent[diff.removed[i]] = false;

    if (emit) {
      await this.core.notifyConsentWillChange(diff.added, diff.removed, ConsentChangeSource.DeveloperSet);
      await this.core.notifyConsentDidChange(diff.added, diff.removed, ConsentChangeSource.DeveloperSet);
      this.scheduleConsentRequest();
    }
  }

  private computeDiff(features: string[], given: boolean): ConsentDiff {
    const added: string[] = [];
    const removed: string[] = [];
    for (let i = 0; i < features.length; i++) {
      const raw: string = features[i];
      if (this.featureGroups[raw]) {
        const expanded: string[] = this.featureGroups[raw];
        for (let j = 0; j < expanded.length; j++) {
          this.classifyOne(expanded[j], given, added, removed);
        }
      } else {
        this.classifyOne(raw, given, added, removed);
      }
    }
    return new ConsentDiff(added, removed);
  }

  private classifyOne(feature: string, given: boolean, added: string[], removed: string[]): void {
    if (this.consent[feature] === undefined) {
      this.config.logger.w(`[ModuleConsent] unknown feature '${feature}'`);
      return;
    }
    if (this.consent[feature] === given) return;
    if (given) added.push(feature);
    else removed.push(feature);
  }

  /**
   * Multiple rapid changes coalesce to a single consent request ~1s later so
   * a cluster of toggles (from a consent dialog) produces one request.
   */
  private scheduleConsentRequest(): void {
    if (this.pendingCoalesceTimer !== null) {
      clearTimeout(this.pendingCoalesceTimer);
    }
    this.pendingCoalesceTimer = setTimeout(() => {
      this.pendingCoalesceTimer = null;
      this.sendSnapshot();
    }, 1000) as number;
  }

  private async sendSnapshot(): Promise<void> {
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['consent'] = JSON.stringify(this.consent);
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
  }

  /**
   * Cancel any pending coalesced consent snapshot. Called from
   * CountlyInstance.halt so a detached instance's timer doesn't fire after
   * shutdown (would produce "already halted" races in tests).
   */
  public cancelPendingTimers(): void {
    if (this.pendingCoalesceTimer !== null) {
      clearTimeout(this.pendingCoalesceTimer);
      this.pendingCoalesceTimer = null;
    }
  }

  /** Test seam — true while the consent-snapshot 1s coalesce timer is armed. */
  public hasActiveTimers(): boolean {
    return this.pendingCoalesceTimer !== null;
  }

  /**
   * Ship the init-time consent snapshot if the constructor flagged one as
   * pending. Called by `CountlyInstance.init()` AFTER
   * `deviceIdModule.resolveInitial()` so `device_id` is populated when
   * `sendSnapshot()` reads it. Also clears any in-flight runtime coalesce
   * timer (the snapshot we're about to send supersedes it).
   *
   * This used to live on the 1-second `scheduleConsentRequest` timer, but
   * on slow storage init that timer could fire before `resolveInitial()`
   * finished, producing a `consent=` request with `device_id=` empty
   * (server 400). The pending-flag approach guarantees the wire request
   * is built only when the device id is known.
   */
  public async flushInitialConsentIfPending(): Promise<void> {
    // Clear any runtime coalesce timer scheduled by setConsentInternal —
    // its pending snapshot is the same one we're about to send anyway.
    if (this.pendingCoalesceTimer !== null) {
      clearTimeout(this.pendingCoalesceTimer);
      this.pendingCoalesceTimer = null;
    }
    if (!this.initialSnapshotPending) return;
    this.initialSnapshotPending = false;
    await this.sendSnapshot();
  }

  /**
   * Used exclusively by `CountlyInstance.resolveUnknownConsent(false)` when
   * the integrator revokes consent from unknown consent mode. Three phases:
   *
   *   1. Flip every consent to false via `setConsentInternal(emit=true)`,
   *      this dispatches `notifyConsentWillChange` + `notifyConsentDidChange`
   *      so modules can clean up their internal state (events queue, active
   *      session, active views, breadcrumbs). Any cleanup wire requests
   *      modules emit are enqueued into the still-paused request queue.
   *   2. The caller clears the request queue, dropping those cleanup
   *      requests AND the original buffered-during-UCM data, the server
   *      never observed the implicit "all granted" state, so it shouldn't
   *      see end_session / location erasure / etc. cleaning it up.
   *   3. Flush the coalesced revocation snapshot scheduled by
   *      `setConsentInternal` so the all-false `consent=` enqueues into
   *      the (now-empty) queue and ships once the caller resumes.
   *
   * Phases 1 and 3 happen here; the caller orchestrates the queue.clear()
   * between them.
   */
  public async applyRevokeFromUnknownMode_phase1(): Promise<void> {
    const all: string[] = CountlyFeatureNames.slice();
    await this.setConsentInternal(all, false, true);
  }

  /**
   * Phase 3 of UCM revoke (see `applyRevokeFromUnknownMode_phase1`). Caller
   * must have run phase 1 + queue.clear() first. Cancels the 1s coalesce
   * timer that phase1's `setConsentInternal` scheduled (we don't want to
   * wait, and we don't want a second snapshot to fire later) and ships
   * the all-false consent snapshot synchronously into the queue. The
   * caller's `resume()` drains it.
   *
   * We don't reuse `flushInitialConsentIfPending` here because that path
   * short-circuits when `initialSnapshotPending=false` (init already
   * flushed it), which it always is on the revoke path. The revocation
   * snapshot is a NEW snapshot, not the init-time one.
   */
  public async applyRevokeFromUnknownMode_phase2(): Promise<void> {
    if (this.pendingCoalesceTimer !== null) {
      clearTimeout(this.pendingCoalesceTimer);
      this.pendingCoalesceTimer = null;
    }
    await this.sendSnapshot();
  }
}
