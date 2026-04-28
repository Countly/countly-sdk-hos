import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import {
  ConsentChangeSource,
  CountlyFeature,
  RCData,
  RCDownloadCallback,
  RequestResult
} from '../../types/Types';

/**
 * Internal cache entry per dev guide §Remote Config Storage:
 *   `v` is the raw decoded value; `c=1` means fresh (downloaded under the
 *   current device id), `c=0` means cached (carried over from a previous user).
 */
interface CacheEntry {
  v: Object | null;
  c: number;
}

const STORAGE_KEY: string = 'cly_remote_config';

/**
 * Remote Config using the modern `method=rc` API (dev guide §4606). Supports
 * full/partial downloads, A/B testing opt-in via the `oi` parameter, automatic
 * trigger-based downloads, value caching across device-ID changes, and
 * persistence so downloaded values survive SDK restart.
 *
 * Implemented A/B testing surface:
 *   - `enrollIntoABTestsForKeys(keys)` — `/o/sdk?method=ab&keys=[...]`
 *   - `exitABTestsForKeys(keys)` — `/o/sdk?method=ab_exit&keys=[...]`
 *   - `getValueAndEnroll(key)` / `getAllValuesAndEnroll()` convenience wrappers
 *
 * NOT implemented (documented gaps):
 *   - Variant-level testing surface (`testingDownloadVariantInformation`,
 *     `testingGetAllVariants`, `testingGetAllExperimentInfo`,
 *     `testingEnrollIntoVariant`) — these are developer-tooling paths for
 *     A/B-test design, not production runtime paths.
 *
 * The legacy `method=fetch_remote_config` API is NOT used — this SDK defaults
 * to the modern API (equivalent to the cross-platform `useExplicitRcApi=true`).
 */
export class ModuleRemoteConfig extends ModuleBase {
  private core: SdkCore;
  private cache: Record<string, CacheEntry> = {};
  private globalCallbacks: RCDownloadCallback[] = [];

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleRemoteConfig] Initialising');
    this.core = core;
    if (config.remoteConfigGlobalCallback) {
      this.globalCallbacks.push(config.remoteConfigGlobalCallback);
    }
  }

  public override async onInit(): Promise<void> {
    // Rehydrate cache from storage so a restart doesn't lose values (dev guide
    // requires persistent RC storage).
    if (this.config.storage) {
      const raw: string = await this.config.storage.getString(STORAGE_KEY, '');
      if (raw.length > 0) {
        try {
          const parsed: Object = JSON.parse(raw);
          if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
            this.cache = parsed as Record<string, CacheEntry>;
          }
        } catch (err) {
          this.config.logger.w(`[ModuleRemoteConfig] onInit, stored cache unparseable — starting empty: ${err}`);
        }
      }
    }

    // Automatic download on init (post-temp-id check, post-consent check).
    if (this.config.remoteConfigAutomaticTriggers
        && this.core.consentModule.hasConsent(CountlyFeature.REMOTE_CONFIG)
        && !this.core.deviceIdModule.isTemporary()) {
      this.fireAutomaticDownload('init');
    }
  }

  // -- Public read API --

  public getValue(key: string): RCData | null {
    const entry: CacheEntry | undefined = this.cache[key];
    if (entry === undefined) return null;
    return new RCData(entry.v, entry.c === 1);
  }

  public getValues(): Record<string, RCData> {
    const out: Record<string, RCData> = {};
    const keys: string[] = Object.keys(this.cache);
    for (let i = 0; i < keys.length; i++) {
      const entry: CacheEntry = this.cache[keys[i]];
      out[keys[i]] = new RCData(entry.v, entry.c === 1);
    }
    return out;
  }

  // -- Download API (modern `method=rc`) --

  public async downloadAllKeys(callback: RCDownloadCallback | null): Promise<void> {
    await this.downloadInternal(null, null, callback);
  }

  public async downloadOmittingKeys(keysToOmit: string[] | null, callback: RCDownloadCallback | null): Promise<void> {
    if (!keysToOmit || keysToOmit.length === 0) {
      await this.downloadInternal(null, null, callback);
      return;
    }
    await this.downloadInternal(null, keysToOmit, callback);
  }

  public async downloadSpecificKeys(keysToInclude: string[] | null, callback: RCDownloadCallback | null): Promise<void> {
    if (!keysToInclude || keysToInclude.length === 0) {
      await this.downloadInternal(null, null, callback);
      return;
    }
    await this.downloadInternal(keysToInclude, null, callback);
  }

  /**
   * Wipe the in-memory + persisted cache. Used by integrators on logout or
   * data-clear flows — separate from the device-id-change automatic wipe.
   */
  public async clearAll(): Promise<void> {
    this.cache = {};
    if (this.config.storage) {
      await this.config.storage.remove(STORAGE_KEY);
    }
  }

  public registerDownloadCallback(cb: RCDownloadCallback): void {
    if (this.globalCallbacks.indexOf(cb) === -1) this.globalCallbacks.push(cb);
  }

  public removeDownloadCallback(cb: RCDownloadCallback): void {
    const i: number = this.globalCallbacks.indexOf(cb);
    if (i !== -1) this.globalCallbacks.splice(i, 1);
  }

  // -- Internal download --

  private async downloadInternal(
    keysToInclude: string[] | null,
    keysToOmit: string[] | null,
    callback: RCDownloadCallback | null
  ): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.REMOTE_CONFIG)) {
      this.config.logger.v('[ModuleRemoteConfig] download, no remote-config consent');
      this.notifyAll(callback, RequestResult.Error, 'no remote-config consent', false, {});
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleRemoteConfig] download, skipped in temporary device ID mode');
      this.notifyAll(callback, RequestResult.Error, 'temporary device ID mode', false, {});
      return;
    }

    const full: boolean = (keysToInclude === null && keysToOmit === null);
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['method'] = 'rc';
    // A/B testing auto-opt-in is controlled via config; `oi=1` enrolls the
    // user in any experiments attached to the returned keys.
    params['oi'] = this.config.remoteConfigABAutoOptin ? '1' : '0';
    if (keysToInclude !== null) {
      params['keys'] = JSON.stringify(keysToInclude);
    } else if (keysToOmit !== null) {
      params['omit_keys'] = JSON.stringify(keysToOmit);
    }
    const qs: string = Utils.buildQueryString(params);

    try {
      const res = await this.config.network.execute(this.config.serverUrl, '/o/sdk', qs, true);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        this.config.logger.w(`[ModuleRemoteConfig] download, http ${res.statusCode}`);
        this.notifyAll(callback, RequestResult.NetworkIssue, `http ${res.statusCode}`, full, {});
        return;
      }
      const parsed: Object = JSON.parse(res.body);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        this.config.logger.e('[ModuleRemoteConfig] download, response was not a JSON object — cache unchanged');
        this.notifyAll(callback, RequestResult.Error, 'invalid payload', full, {});
        return;
      }

      const serverObj: Record<string, Object> = parsed as Record<string, Object>;
      const serverKeys: string[] = Object.keys(serverObj);

      // Full download: replace the whole cache. Partial: merge keys that
      // arrived over the existing cache, leaving untouched keys at whatever
      // freshness they previously had. ArkTS bans Object.assign — build the
      // clone explicitly instead.
      const next: Record<string, CacheEntry> = {};
      if (!full) {
        const cacheKeys: string[] = Object.keys(this.cache);
        for (let i = 0; i < cacheKeys.length; i++) next[cacheKeys[i]] = this.cache[cacheKeys[i]];
      }
      const downloadedValues: Record<string, RCData> = {};
      for (let i = 0; i < serverKeys.length; i++) {
        const k: string = serverKeys[i];
        const v: Object = serverObj[k];
        next[k] = { v: v, c: 1 };
        downloadedValues[k] = new RCData(v, true);
      }
      this.cache = next;
      await this.persistCache();
      this.notifyAll(callback, RequestResult.Success, null, full, downloadedValues);
    } catch (err) {
      this.config.logger.e(`[ModuleRemoteConfig] download, failed: ${err}`);
      this.notifyAll(callback, RequestResult.NetworkIssue, String(err), full, {});
    }
  }

  private notifyAll(
    perCall: RCDownloadCallback | null,
    result: RequestResult,
    error: string | null,
    fullValueUpdate: boolean,
    downloaded: Record<string, RCData>
  ): void {
    if (perCall !== null) {
      try { perCall(result, error, fullValueUpdate, downloaded); }
      catch (e) { this.config.logger.e(`[ModuleRemoteConfig] callback threw: ${e}`); }
    }
    for (let i = 0; i < this.globalCallbacks.length; i++) {
      try { this.globalCallbacks[i](result, error, fullValueUpdate, downloaded); }
      catch (e) { this.config.logger.e(`[ModuleRemoteConfig] global callback threw: ${e}`); }
    }
  }

  private async persistCache(): Promise<void> {
    if (!this.config.storage) return;
    try {
      const ok: boolean = await this.config.storage.setString(STORAGE_KEY, JSON.stringify(this.cache));
      if (!ok) {
        this.config.logger.w('[ModuleRemoteConfig] persistCache, setString returned false — cache will be lost on restart');
      }
    } catch (err) {
      this.config.logger.e(`[ModuleRemoteConfig] persistCache, failed: ${err}`);
    }
  }

  public override async onDeviceIdChangedNotMerged(oldId: string, _newId: string): Promise<void> {
    if (this.config.remoteConfigValueCaching) {
      // Value caching enabled: keep all keys but demote them to stale
      // (c=0 → isCurrentUsersData=false). The next successful download will
      // freshen the values it actually fetches.
      const keys: string[] = Object.keys(this.cache);
      for (let i = 0; i < keys.length; i++) this.cache[keys[i]] = { v: this.cache[keys[i]].v, c: 0 };
      await this.persistCache();
    } else {
      this.cache = {};
      if (this.config.storage) await this.config.storage.remove(STORAGE_KEY);
    }
    // Automatic download hook — the caller has already reset consent, so only
    // re-fetch when RC consent survives (consent was re-granted to the new
    // user) or requiresConsent is off.
    if (this.config.remoteConfigAutomaticTriggers
        && this.core.consentModule.hasConsent(CountlyFeature.REMOTE_CONFIG)
        && !this.core.deviceIdModule.isTemporary()) {
      this.fireAutomaticDownload(`deviceIdChangedNotMerged(wasTemp=${oldId === 'CLYTemporaryDeviceID'})`);
    }
  }

  public override async onDeviceIdChangedMerged(oldId: string, _newId: string): Promise<void> {
    // With-merge keeps the previous user's identity — values stay valid.
    // Still re-trigger an automatic download so the new session picks up
    // anything the server routed under the new id.
    if (this.config.remoteConfigAutomaticTriggers
        && this.core.consentModule.hasConsent(CountlyFeature.REMOTE_CONFIG)
        && !this.core.deviceIdModule.isTemporary()) {
      this.fireAutomaticDownload(`deviceIdChangedMerged(wasTemp=${oldId === 'CLYTemporaryDeviceID'})`);
    }
  }

  public override async onConsentChanged(added: string[], _removed: string[], _source: ConsentChangeSource): Promise<void> {
    // Dev guide §Consent: revocation does NOT clear the in-memory cache —
    // only `clearAll()` or device-id-change-not-merged wipes. On a grant we
    // optionally kick off an automatic download.
    if (added.indexOf(CountlyFeature.REMOTE_CONFIG) !== -1
        && this.config.remoteConfigAutomaticTriggers
        && !this.core.deviceIdModule.isTemporary()) {
      this.fireAutomaticDownload('consentGranted');
    }
  }

  public override async onHalt(): Promise<void> {
    this.cache = {};
  }

  // -- A/B testing --

  /**
   * Enroll the user in every A/B experiment that touches `keys`. Sends
   * `/o/sdk?method=ab&keys=[...]`. No-op in temporary-id mode or under revoked
   * RC consent; invalid / empty keys are filtered with a warning.
   */
  public async enrollIntoABTestsForKeys(keys: string[] | null): Promise<void> {
    const filtered: string[] = ModuleRemoteConfig.filterKeys(keys);
    if (filtered.length === 0) {
      this.config.logger.w('[ModuleRemoteConfig] enrollIntoABTestsForKeys, no valid keys — omitted');
      return;
    }
    if (!this.canSendAB('enrollIntoABTestsForKeys')) return;
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['method'] = 'ab';
    params['keys'] = JSON.stringify(filtered);
    const qs: string = Utils.buildQueryString(params);
    try {
      await this.config.network.execute(this.config.serverUrl, '/o/sdk', qs, true);
    } catch (err) {
      this.config.logger.e(`[ModuleRemoteConfig] enrollIntoABTestsForKeys, request failed: ${err}`);
    }
  }

  /**
   * Exit the user from A/B experiments. `null`/empty means "exit from all".
   * Sends `/o/sdk?method=ab_exit[&keys=[...]]`. No-op in temporary-id mode or
   * under revoked RC consent.
   */
  public async exitABTestsForKeys(keys: string[] | null): Promise<void> {
    if (!this.canSendAB('exitABTestsForKeys')) return;
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['method'] = 'ab_exit';
    const filtered: string[] = ModuleRemoteConfig.filterKeys(keys);
    if (filtered.length > 0) params['keys'] = JSON.stringify(filtered);
    const qs: string = Utils.buildQueryString(params);
    try {
      await this.config.network.execute(this.config.serverUrl, '/o/sdk', qs, true);
    } catch (err) {
      this.config.logger.e(`[ModuleRemoteConfig] exitABTestsForKeys, request failed: ${err}`);
    }
  }

  /**
   * Convenience: return `getValue(key)` and enroll the caller in the A/B
   * tests attached to that key. No enroll fires if the key is unknown.
   */
  public async getValueAndEnroll(key: string): Promise<RCData | null> {
    const value: RCData | null = this.getValue(key);
    if (value !== null) await this.enrollIntoABTestsForKeys([key]);
    return value;
  }

  /**
   * Convenience: return every cached value and enroll in every associated
   * A/B test. Empty cache → empty return + no enroll request.
   */
  public async getAllValuesAndEnroll(): Promise<Record<string, RCData>> {
    const all: Record<string, RCData> = this.getValues();
    const keys: string[] = Object.keys(all);
    if (keys.length > 0) await this.enrollIntoABTestsForKeys(keys);
    return all;
  }

  // -- Internals --

  private canSendAB(caller: string): boolean {
    if (!this.core.consentModule.hasConsent(CountlyFeature.REMOTE_CONFIG)) {
      this.config.logger.v(`[ModuleRemoteConfig] ${caller}, no remote-config consent — omitted`);
      return false;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d(`[ModuleRemoteConfig] ${caller}, temporary device ID mode — omitted`);
      return false;
    }
    return true;
  }

  private static filterKeys(keys: string[] | null): string[] {
    if (!keys) return [];
    const out: string[] = [];
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (k && k.length > 0) out.push(k);
    }
    return out;
  }

  /**
   * Fire an automatic download, fire-and-forget. Triggers are best-effort
   * side effects (init, consent grant, device-id change) — a failure here
   * shouldn't block the caller but must be logged.
   */
  private fireAutomaticDownload(reason: string): void {
    this.config.logger.d(`[ModuleRemoteConfig] auto-trigger, downloading (reason=${reason})`);
    this.downloadAllKeys(null).catch((err: Object) => {
      this.config.logger.e(`[ModuleRemoteConfig] auto-trigger (${reason}) rejected: ${err}`);
    });
  }
}
