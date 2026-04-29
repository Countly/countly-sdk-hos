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
  // causing a collision with "no timer scheduled" — manifests as the
  // init-time `flushInitialConsentIfPending` no-op'ing and the consent
  // snapshot deferring to the 1-second coalesce timer instead of shipping
  // before begin_session. Browsers and Node return positive ids so the older
  // `=== 0` sentinel was idiomatic but not portable.
  private pendingCoalesceTimer: number | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleConsent] Initialising');
    this.core = core;
    this.requiresConsent = config.requiresConsent;
    for (let i = 0; i < CountlyFeatureNames.length; i++) {
      this.consent[CountlyFeatureNames[i]] = !this.requiresConsent;
    }
    if (this.requiresConsent) {
      // emit=false skips the will/did-change module dispatch — at construction
      // time other modules aren't wired into core yet, so dispatching their
      // hooks would NPE. We still schedule the coalesced server snapshot so
      // the initial-consent state reaches the wire (matches Android's
      // initTimeSetConsentRQ behavior).
      let initialMutationApplied: boolean = false;
      if (config.initialConsentAll) {
        this.giveConsentAllInternal(false).catch((err: Object) => {
          this.config.logger.e(`[ModuleConsent] constructor giveConsentAllInternal rejected: ${err}`);
        });
        initialMutationApplied = true;
      } else if (config.initialConsent.length > 0) {
        this.giveConsentInternal(config.initialConsent, false).catch((err: Object) => {
          this.config.logger.e(`[ModuleConsent] constructor giveConsentInternal rejected: ${err}`);
        });
        initialMutationApplied = true;
      }
      if (initialMutationApplied) {
        this.scheduleConsentRequest();
      }
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
    if (!this.requiresConsent) {
      this.config.logger.v('[ModuleConsent] giveConsent, requiresConsent is false — ignored');
      return;
    }
    // Fire-and-log: callers (public API) are synchronous; we still want any
    // rejection surfaced via the logger rather than an unhandled rejection.
    void this.giveConsentInternal(features, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] giveConsent chain rejected: ${err}`);
    });
  }

  public removeConsent(features: string[]): void {
    if (!this.requiresConsent) {
      this.config.logger.v('[ModuleConsent] removeConsent, requiresConsent is false — ignored');
      return;
    }
    void this.setConsentInternal(features, false, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] removeConsent chain rejected: ${err}`);
    });
  }

  public giveConsentAll(): void {
    if (!this.requiresConsent) return;
    void this.giveConsentAllInternal(true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] giveConsentAll chain rejected: ${err}`);
    });
  }

  public removeConsentAll(): void {
    if (!this.requiresConsent) return;
    const all: string[] = CountlyFeatureNames.slice();
    void this.setConsentInternal(all, false, true).catch((err: Object) => {
      this.config.logger.e(`[ModuleConsent] removeConsentAll chain rejected: ${err}`);
    });
  }

  public setConsent(features: string[], given: boolean): void {
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
    this.featureGroups[groupName] = features.slice();
  }

  public setConsentFeatureGroup(groupName: string, given: boolean): void {
    const features: string[] | undefined = this.featureGroups[groupName];
    if (!features) {
      this.config.logger.w(`[ModuleConsent] setConsentFeatureGroup, unknown group '${groupName}'`);
      return;
    }
    this.setConsent(features, given);
  }

  /**
   * Reset consents when device ID changes without merge. Does NOT schedule a
   * consent snapshot request — the source tag documents that this flow
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
   *      `giveConsent` returns sees the new value (Android parity — Java's
   *      synchronous listeners can't observe a pre-mutation state either)
   *   3. await notifyConsentWillChange so modules can flush in-flight work
   *   4. await notifyConsentDidChange; schedule the coalesced server snapshot
   *
   * willChange listeners receive the diff (added/removed lists) and the
   * source — they should drive their cleanup off those parameters, not by
   * re-querying `hasConsent` for the modified features.
   */
  private async setConsentInternal(features: string[], given: boolean, emit: boolean): Promise<void> {
    const diff: ConsentDiff = this.computeDiff(features, given);
    if (diff.added.length === 0 && diff.removed.length === 0) return;

    // Apply the diff synchronously (before any await) so the public
    // giveConsent/removeConsent contract is "state is updated by the time the
    // call returns" — anything else makes synchronous getConsent unreliable.
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

  /**
   * Send any init-time consent snapshot synchronously, bypassing the 1-second
   * coalesce timer scheduled by the constructor. Called from
   * `CountlyInstance.init()` after `deviceIdModule.resolveInitial()` so the
   * initial consent state lands on the wire ahead of any `begin_session` /
   * other module request — the platform's `onApplicationForeground` arrives
   * after `init()` resolves but well before the 1s timer would fire, so
   * without this flush the queue ends up with `begin_session` ahead of the
   * consent change. (The 1s timer remains correct for runtime consent dialog
   * toggles where multiple changes coalesce to a single request.)
   */
  public async flushInitialConsentIfPending(): Promise<void> {
    if (this.pendingCoalesceTimer === null) return;
    clearTimeout(this.pendingCoalesceTimer);
    this.pendingCoalesceTimer = null;
    await this.sendSnapshot();
  }
}
