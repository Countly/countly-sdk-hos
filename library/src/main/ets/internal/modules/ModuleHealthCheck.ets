import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { HealthListener } from '../RequestQueue';
import { CountlyFeature } from '../../types/Types';

const STORAGE_KEY: string = 'HEALTH_CHECK';
/**
 * Automatically detected crashes. ModuleCrashes counts them here, outside the
 * health check state, and the next start adds them to "crashes" / "record:a".
 */
export const HEALTH_CHECK_CRASH_COUNT_KEY: string = 'HEALTH_CHECK_AUTOMATIC_CRASHES';
const ERROR_MESSAGE_MAX: number = 1000;
/** A method usage or log code count stops growing here until it is reported. */
const COUNT_CAP: number = 65535;
/** Feature areas of the method usage, each following the consent of the same name. */
const AREAS: string[] = [CountlyFeature.SESSIONS, CountlyFeature.EVENTS, CountlyFeature.VIEWS, CountlyFeature.CRASHES];

/**
 * Persisted schema, matches the dev guide §Health Checks Storage spec
 * verbatim so the in-memory counter can be rehydrated across restarts.
 * A class (not interface) so ArkTS strict mode can serialize/deserialize
 * under the nominal-typing + no-untyped-obj-literals rules.
 */
class StoredState {
  public LErr: number;
  public LWar: number;
  public RStatC: number;
  public REMsg: string;
  public BReq: number;
  public CBReq: number;
  public MU: Record<string, Record<string, number>>;
  public LC: Record<string, number>;

  constructor(LErr: number, LWar: number, RStatC: number, REMsg: string, BReq: number, CBReq: number,
    MU: Record<string, Record<string, number>>, LC: Record<string, number>) {
    this.LErr = LErr;
    this.LWar = LWar;
    this.RStatC = RStatC;
    this.REMsg = REMsg;
    this.BReq = BReq;
    this.CBReq = CBReq;
    this.MU = MU;
    this.LC = LC;
  }
}

/** The counters as one health check reports them, kept until the request completes. */
class HealthSnapshot {
  public el: number = 0;
  public wl: number = 0;
  public sc: number = -1;
  public em: string = '';
  public bom: number = 0;
  public cbom: number = 0;
  public fu: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  public lc: Map<string, number> = new Map<string, number>();
}

/**
 * SDK Health Monitoring. Tracks internal error/warning log counts, the last
 * queued request the server refused, the backoff counters, how often the
 * session, event, view and crash methods are called (method usage) and how
 * often known problems occurred (log codes); sends a single immediate
 * `/i?hc={...}` request after init. No consent is required (internal
 * diagnostic, no PII involved), but the method usage of a feature and the
 * log codes its calls record follow that feature's consent.
 *
 * Dev guide §Health Checks. State persists across restarts so a crashed app's
 * counters still get reported on the next launch. A successful acknowledgement
 * (2xx and a response JSON with `result`) takes the reported amounts away.
 *
 * Nothing here logs at warning or error level: those logs are counted here,
 * so they would count themselves.
 */
export class ModuleHealthCheck extends ModuleBase {
  private core: SdkCore;
  private sent: boolean = false;
  /** Handle for the deferred initial send (setTimeout(0) in onInit). Stored
   *  so `onHalt` can cancel it, otherwise a stop/halt that happens between
   *  scheduling and firing lets the HC enqueue an extra request after the
   *  instance is supposed to be quiet. `null` = not scheduled or already
   *  fired. We don't use 0 as a sentinel because HMOS setTimeout may
   *  legitimately return 0 (same gotcha as elsewhere in the SDK). */
  private initialSendTimer: number | null = null;

  private countLogWarning: number = 0;
  private countLogError: number = 0;
  private statusCode: number = -1;
  private errorMessage: string = '';
  private countBackoffRequest: number = 0;
  /** Backoffs in a row with no request answered in time in between; memory only, a restart ends the run. */
  private consecutiveBackoffRequestCounter: number = 0;
  private maxConsecutiveBackoff: number = 0;
  private methodUsage: Map<string, Map<string, number>> = new Map<string, Map<string, number>>();
  private logCodes: Map<string, number> = new Map<string, number>();

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleHealthCheck] Initialising');
    this.core = core;
    // Counting starts right away, also while the health check request is
    // disabled; warnings, errors and codes the logger kept from before this
    // module existed are handed over by these calls.
    this.config.logger.setHealthListener((isError: boolean) => {
      if (isError) this.countLogError++;
      else this.countLogWarning++;
    });
    this.config.logger.setHealthCodeListener((code: string, area: string) => {
      this.recordLogCode(code, area);
    });
    this.config.logger.setHealthUsageListener((area: string, method: string) => {
      this.recordUsage(area, method);
    });
    // Hook the request queue so refused requests + backoff events bump counters.
    // ArkTS strict mode bans object-literal interface implementations
    // (arkts-no-untyped-obj-literals), use a named adapter class instead.
    this.core.requestQueue.setHealthListener(new HealthCheckQueueListener(this));
  }

  public override async onInit(): Promise<void> {
    // Restore persisted counters first so a crash+restart doesn't lose them.
    await this.loadState();

    if (this.config.disableHealthCheck) {
      this.config.logger.d('[ModuleHealthCheck] onInit, health check disabled by config, no report will be sent');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleHealthCheck] onInit, temporary device ID mode, the report is sent when it ends');
      return;
    }

    if (this.config.unknownConsentMode) {
      // Don't schedule the init-time send while UCM is active.
      // `resolveUnknownConsent` calls `triggerPostUcmSend()` on exit
      // (both grant and revoke paths) to fire the report. Matches
      // Dart's `_attemptHealthCheck` init gate + `_getOutOfUnknownConsent
      // State` post-exit fire.
      this.config.logger.d('[ModuleHealthCheck] onInit, in unknown consent mode, deferring health check until UCM resolves');
      return;
    }

    // Defer the first send to the next macrotask. The counter snapshot inside
    // sendHealthCheck is synchronous up to its first await, so a fire-and-
    // forget call here would race with anything the integrator (or test) does
    // synchronously after init returns. With setTimeout(0), the snapshot
    // happens after the microtask queue drains, giving post-init synchronous
    // activity a chance to reach the counters first. Best-effort, a failure
    // keeps counters in storage for the next launch.
    this.initialSendTimer = setTimeout(() => {
      this.initialSendTimer = null;
      this.sendHealthCheck().catch((err: Object) => {
        this.config.logger.d(`[ModuleHealthCheck] sendHealthCheck rejected: ${err}`);
      });
    }, 0) as number;
  }

  /**
   * Called by `CountlyInstance.resolveUnknownConsent` on UCM exit (both
   * grant and revoke paths), when a temporary device ID is replaced by a
   * real one, and when offline mode ends, to fire the health check that
   * `onInit` deferred. No-op if HC is disabled, still in temp-id mode or
   * offline mode, or already sent this lifecycle.
   * Fire-and-forget per the Dart parity protocol.
   */
  public triggerPostUcmSend(): void {
    if (this.config.disableHealthCheck) return;
    if (this.core.deviceIdModule.isTemporary()) return;
    if (this.config.unknownConsentMode) return;
    if (this.sent) return;
    this.sendHealthCheck().catch((err: Object) => {
      this.config.logger.d(`[ModuleHealthCheck] post-UCM sendHealthCheck rejected: ${err}`);
    });
  }

  public override async onHalt(): Promise<void> {
    // Cancel the deferred initial send if it hasn't fired yet. Without this,
    // a stop()/halt() that lands between scheduling and firing lets the HC
    // enqueue/send an extra request after the instance is supposed to be
    // quiet, breaking post-halt invariants ("no new wire traffic after halt").
    if (this.initialSendTimer !== null) {
      clearTimeout(this.initialSendTimer);
      this.initialSendTimer = null;
    }
    this.config.logger.setHealthPaused(false);
    // Persist on shutdown so activity-stop / session-end lifecycle events
    // don't lose counters for unsent reports.
    await this.saveState();
  }

  /** Test seam — true while the deferred initial-send setTimeout is armed. */
  public hasActiveTimers(): boolean {
    return this.initialSendTimer !== null;
  }

  // -- Counter mutators (called from Logger + RequestQueue listeners) --

  /**
   * Keeps the status code and the answer of the last queued request the
   * server answered with a failure. A request that got no answer has no
   * valid status code and changes nothing.
   */
  public logFailedNetworkRequest(statusCode: number, errorResponse: string): void {
    if (!(statusCode > 0 && statusCode < 1000)) return;
    const text: string = errorResponse ? errorResponse : '';
    this.statusCode = statusCode;
    this.errorMessage = text.length > ERROR_MESSAGE_MAX ? text.substring(0, ERROR_MESSAGE_MAX) : text;
  }

  /**
   * Counts a backoff and extends the current run of backoffs in a row. The
   * longest run is raised right away, so no save has to end the run to keep
   * it. Records log code w320, and w321 when the backoff continues a run.
   */
  public logBackoffRequest(): void {
    const continuesRun: boolean = this.consecutiveBackoffRequestCounter > 0;
    this.countBackoffRequest++;
    this.consecutiveBackoffRequestCounter++;
    if (this.consecutiveBackoffRequestCounter > this.maxConsecutiveBackoff) {
      this.maxConsecutiveBackoff = this.consecutiveBackoffRequestCounter;
    }
    this.recordLogCode('w320', '');
    if (continuesRun) this.recordLogCode('w321', '');
  }

  /** Ends the current run of backoffs, after a queued request was answered in time. */
  public logConsecutiveBackoffEnd(): void {
    this.consecutiveBackoffRequestCounter = 0;
  }

  /**
   * Counts a call of a method of the session, event, view or crash feature,
   * only while the feature has consent. `method` carries ':a' for a call the
   * SDK made by itself. The logger holds these calls back while an
   * automatically detected crash is reported.
   */
  public recordUsage(area: string, method: string): void {
    if (area.length === 0 || method.length === 0) return;
    if (AREAS.indexOf(area) === -1 || !this.areaHasConsent(area)) return;
    let methods: Map<string, number> | undefined = this.methodUsage.get(area);
    if (methods === undefined) {
      methods = new Map<string, number>();
      this.methodUsage.set(area, methods);
    }
    ModuleHealthCheck.addCount(methods, method, 1);
  }

  /**
   * Counts a known problem. A code that a method of a feature area records
   * passes the area ('' for none) and is counted only while that feature has
   * consent.
   */
  public recordLogCode(code: string, area: string): void {
    if (code.length === 0) return;
    if (area.length > 0 && AREAS.indexOf(area) !== -1 && !this.areaHasConsent(area)) return;
    ModuleHealthCheck.addCount(this.logCodes, code, 1);
  }

  /**
   * Whether the user gave the consent of a feature area. Unknown consent mode
   * grants every feature only so data can wait locally for the answer, so
   * nothing is counted until that answer comes.
   */
  private areaHasConsent(area: string): boolean {
    if (this.config.unknownConsentMode) return false;
    return this.core.consentModule.hasConsent(area);
  }

  private static addCount(counts: Map<string, number>, name: string, amount: number): void {
    const current: number | undefined = counts.get(name);
    const next: number = (current === undefined ? 0 : current) + amount;
    counts.set(name, next > COUNT_CAP ? COUNT_CAP : next);
  }

  private static subtractCounts(counts: Map<string, number>, sent: Map<string, number>): void {
    sent.forEach((amount: number, name: string) => {
      const current: number | undefined = counts.get(name);
      const left: number = (current === undefined ? 0 : current) - amount;
      if (left > 0) {
        counts.set(name, left);
      } else {
        counts.delete(name);
      }
    });
  }

  /** The counters as the health check reports them. */
  private snapshot(): HealthSnapshot {
    const s: HealthSnapshot = new HealthSnapshot();
    s.el = this.countLogError;
    s.wl = this.countLogWarning;
    s.sc = this.statusCode;
    s.em = this.errorMessage;
    s.bom = this.countBackoffRequest;
    s.cbom = this.maxConsecutiveBackoff;
    this.methodUsage.forEach((methods: Map<string, number>, area: string) => {
      const copy: Map<string, number> = new Map<string, number>();
      methods.forEach((count: number, method: string) => {
        copy.set(method, count);
      });
      s.fu.set(area, copy);
    });
    this.logCodes.forEach((count: number, code: string) => {
      s.lc.set(code, count);
    });
    return s;
  }

  /**
   * Takes away what a health check the server accepted reported, so what was
   * counted while it was on its way is reported next time. The last failed
   * request and the longest backoff run are cleared only while they still
   * hold the reported values.
   */
  private clearSentValues(sent: HealthSnapshot): void {
    this.countLogError = Math.max(0, this.countLogError - sent.el);
    this.countLogWarning = Math.max(0, this.countLogWarning - sent.wl);
    this.countBackoffRequest = Math.max(0, this.countBackoffRequest - sent.bom);
    if (this.maxConsecutiveBackoff === sent.cbom) this.maxConsecutiveBackoff = 0;
    if (this.statusCode === sent.sc && this.errorMessage === sent.em) {
      this.statusCode = -1;
      this.errorMessage = '';
    }
    sent.fu.forEach((methods: Map<string, number>, area: string) => {
      const counted: Map<string, number> | undefined = this.methodUsage.get(area);
      if (counted === undefined) return;
      ModuleHealthCheck.subtractCounts(counted, methods);
      if (counted.size === 0) this.methodUsage.delete(area);
    });
    ModuleHealthCheck.subtractCounts(this.logCodes, sent.lc);
  }

  private static usageToRecord(usage: Map<string, Map<string, number>>): Record<string, Record<string, number>> {
    const out: Record<string, Record<string, number>> = {};
    usage.forEach((methods: Map<string, number>, area: string) => {
      out[area] = ModuleHealthCheck.countsToRecord(methods);
    });
    return out;
  }

  private static countsToRecord(counts: Map<string, number>): Record<string, number> {
    const out: Record<string, number> = {};
    counts.forEach((count: number, name: string) => {
      out[name] = count;
    });
    return out;
  }

  // -- Internal send --

  private async sendHealthCheck(): Promise<void> {
    if (this.sent) return;
    // Not marked as sent: `disableOfflineMode` sends it.
    if (this.config.offlineMode) {
      this.config.logger.d('[ModuleHealthCheck] sendHealthCheck, offline mode, the report is sent when it ends');
      return;
    }
    this.sent = true;
    // Aborted while networking is turned off by the SDK Behavior Settings;
    // the counters wait for the next SDK initialization.
    if (!this.config.serverConfig.networkingEnabled) {
      this.config.logger.d('[ModuleHealthCheck] sendHealthCheck, networking disabled by server config, the counters wait for the next start');
      return;
    }

    const sent: HealthSnapshot = this.snapshot();
    const base: Record<string, string> = this.core.requestBuilder.baseParams();
    // Metrics contains only the app version, and only with the "metrics"
    // consent. The override (if any) is the same value `DeviceInfo.collect`
    // would return for `_app_version`, so resolve it directly.
    if (this.core.consentModule.hasConsent(CountlyFeature.METRICS)) {
      const appVersion: string = this.config.metricOverride['_app_version'] !== undefined
        ? this.config.metricOverride['_app_version']
        : this.config.appVersion;
      const metricsObj: Record<string, string> = { '_app_version': appVersion };
      base['metrics'] = JSON.stringify(metricsObj);
    }
    const hcObj: Record<string, Object> = {
      'el': sent.el,
      'wl': sent.wl,
      'sc': sent.sc,
      'em': sent.em,
      'bom': sent.bom,
      'cbom': sent.cbom,
      'fu': ModuleHealthCheck.usageToRecord(sent.fu),
      'lc': ModuleHealthCheck.countsToRecord(sent.lc)
    };
    base['hc'] = JSON.stringify(hcObj);
    const qs: string = Utils.buildQueryString(base);

    try {
      const res = await this.config.network.execute(this.config.serverUrl, '/i', qs, true);
      if (res.statusCode >= 200 && res.statusCode < 300) {
        try {
          const parsed: Object = JSON.parse(res.body);
          const parsedRec: Record<string, Object> = parsed as Record<string, Object>;
          if (parsedRec['result'] !== undefined) {
            this.clearSentValues(sent);
            await this.saveState();
            this.config.logger.d('[ModuleHealthCheck] server acknowledged, the reported counts were taken away');
            return;
          }
        } catch (parseErr) {
          this.config.logger.d(`[ModuleHealthCheck] 2xx unparseable, retaining counters: ${parseErr}`);
        }
      } else {
        this.config.logger.d(`[ModuleHealthCheck] http ${res.statusCode}, retaining counters for next launch`);
      }
      // Retain on any failure path so the next launch re-sends.
      await this.saveState();
    } catch (err) {
      this.config.logger.d(`[ModuleHealthCheck] network error, retaining counters: ${err}`);
      await this.saveState();
    }
  }

  // -- Persistence --

  private async loadState(): Promise<void> {
    if (!this.config.storage) return;
    const raw: string = await this.config.storage.getString(STORAGE_KEY, '');
    if (raw.length > 0) {
      let parsed: Object | null = null;
      try {
        parsed = JSON.parse(raw) as Object;
      } catch (err) {
        parsed = null;
      }
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        // Dev guide: malformed → reset + clear, counted with log code e503.
        // This module counts warnings and errors itself, so it logs at debug.
        this.config.logger.d('[ModuleHealthCheck] loadState, stored state malformed, resetting');
        await this.clearAndSave();
        this.recordLogCode('e503', '');
      } else {
        this.addStored(parsed as Record<string, Object>);
      }
    }

    // Crashes the previous run detected by itself, counted outside this state.
    const crashes: number = parseInt(await this.config.storage.getString(HEALTH_CHECK_CRASH_COUNT_KEY, '0'), 10);
    if (Number.isFinite(crashes) && crashes > 0) {
      let methods: Map<string, number> | undefined = this.methodUsage.get(CountlyFeature.CRASHES);
      if (methods === undefined) {
        methods = new Map<string, number>();
        this.methodUsage.set(CountlyFeature.CRASHES, methods);
      }
      ModuleHealthCheck.addCount(methods, 'record:a', crashes);
      await this.saveState();
      await this.config.storage.setString(HEALTH_CHECK_CRASH_COUNT_KEY, '0');
    }
  }

  /**
   * Adds a stored state to what was counted before it could be read. An
   * entry of the wrong type is skipped.
   */
  private addStored(s: Record<string, Object>): void {
    this.countLogError += this.safeCount(s['LErr']);
    this.countLogWarning += this.safeCount(s['LWar']);
    // A request refused before the stored state was read is the most recent failure, so it stays.
    if (this.statusCode === -1) {
      const storedStatus: Object = s['RStatC'];
      if (typeof storedStatus === 'number' && Number.isFinite(storedStatus as number)) this.statusCode = storedStatus as number;
      const storedMessage: Object = s['REMsg'];
      if (typeof storedMessage === 'string') this.errorMessage = storedMessage as string;
    }
    this.countBackoffRequest += this.safeCount(s['BReq']);
    this.maxConsecutiveBackoff = Math.max(this.maxConsecutiveBackoff, this.safeCount(s['CBReq']));

    const storedUsage: Object = s['MU'];
    if (storedUsage !== null && storedUsage !== undefined && typeof storedUsage === 'object' && !Array.isArray(storedUsage)) {
      const usage: Record<string, Object> = storedUsage as Record<string, Object>;
      const areas: string[] = Object.keys(usage);
      for (let i = 0; i < areas.length; i++) {
        const area: string = areas[i];
        const storedMethods: Object = usage[area];
        if (AREAS.indexOf(area) === -1 || storedMethods === null || typeof storedMethods !== 'object' || Array.isArray(storedMethods)) continue;
        const methodsRec: Record<string, Object> = storedMethods as Record<string, Object>;
        const names: string[] = Object.keys(methodsRec);
        for (let j = 0; j < names.length; j++) {
          const count: number = this.safeCount(methodsRec[names[j]]);
          if (count <= 0) continue;
          let methods: Map<string, number> | undefined = this.methodUsage.get(area);
          if (methods === undefined) {
            methods = new Map<string, number>();
            this.methodUsage.set(area, methods);
          }
          ModuleHealthCheck.addCount(methods, names[j], count);
        }
      }
    }

    const storedCodes: Object = s['LC'];
    if (storedCodes !== null && storedCodes !== undefined && typeof storedCodes === 'object' && !Array.isArray(storedCodes)) {
      const codesRec: Record<string, Object> = storedCodes as Record<string, Object>;
      const codes: string[] = Object.keys(codesRec);
      for (let i = 0; i < codes.length; i++) {
        const count: number = this.safeCount(codesRec[codes[i]]);
        if (count > 0) ModuleHealthCheck.addCount(this.logCodes, codes[i], count);
      }
    }
  }

  /**
   * Stores all counters, the method usage and log codes included. Called on
   * the session update timer, at the end of a session, when the app goes to
   * the background, on halt and after a health check.
   */
  public async saveState(): Promise<void> {
    if (!this.config.storage) return;
    const state: StoredState = new StoredState(
      this.countLogError,
      this.countLogWarning,
      this.statusCode,
      this.errorMessage,
      this.countBackoffRequest,
      this.maxConsecutiveBackoff,
      ModuleHealthCheck.usageToRecord(this.methodUsage),
      ModuleHealthCheck.countsToRecord(this.logCodes)
    );
    try {
      await this.config.storage.setString(STORAGE_KEY, JSON.stringify(state));
    } catch (err) {
      this.config.logger.d(`[ModuleHealthCheck] saveState, failed: ${err}`);
    }
  }

  private async clearAndSave(): Promise<void> {
    this.countLogError = 0;
    this.countLogWarning = 0;
    this.statusCode = -1;
    this.errorMessage = '';
    this.countBackoffRequest = 0;
    this.consecutiveBackoffRequestCounter = 0;
    this.maxConsecutiveBackoff = 0;
    this.methodUsage.clear();
    this.logCodes.clear();
    if (this.config.storage) {
      await this.config.storage.remove(STORAGE_KEY);
    }
  }

  private safeCount(v: Object | undefined): number {
    return (typeof v === 'number' && Number.isFinite(v as number) && (v as number) > 0) ? Math.floor(v as number) : 0;
  }
}

/**
 * Named adapter class satisfying `HealthListener`. Required because ArkTS
 * strict mode's `arkts-no-untyped-obj-literals` rule forbids passing an
 * object literal where an interface is expected.
 */
class HealthCheckQueueListener implements HealthListener {
  private module: ModuleHealthCheck;
  constructor(module: ModuleHealthCheck) { this.module = module; }
  onFailedRequest(statusCode: number, body: string): void {
    this.module.logFailedNetworkRequest(statusCode, body);
  }
  onBackoff(): void { this.module.logBackoffRequest(); }
  onSuccessfulSend(): void { this.module.logConsecutiveBackoffEnd(); }
}
