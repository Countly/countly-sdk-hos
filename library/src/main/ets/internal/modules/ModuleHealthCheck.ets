import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { DeviceInfo } from '../DeviceInfo';
import { Utils } from '../Utils';
import { HealthListener } from '../RequestQueue';

const STORAGE_KEY: string = 'HEALTH_CHECK';
const ERROR_MESSAGE_MAX: number = 1000;

/**
 * Persisted schema — matches the dev guide §Health Checks Storage spec
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

  constructor(LErr: number, LWar: number, RStatC: number, REMsg: string, BReq: number, CBReq: number) {
    this.LErr = LErr;
    this.LWar = LWar;
    this.RStatC = RStatC;
    this.REMsg = REMsg;
    this.BReq = BReq;
    this.CBReq = CBReq;
  }
}

/**
 * SDK Health Monitoring. Tracks internal error/warning log counts, the last
 * failed network request, and backoff counters; sends a single immediate
 * `/i?hc={...}` request after init. No consent is required (internal
 * diagnostic — no PII involved).
 *
 * Dev guide §Health Checks. State persists across restarts so a crashed app's
 * counters still get reported on the next launch. A successful acknowledgement
 * (response JSON contains `result`) clears both in-memory and persisted state.
 *
 * This module is wired to the Logger (via `setHealthListener`) and the
 * RequestQueue (via `setHealthListener`) — when those paths fire a warn / error
 * log or a failed network request, the counter increments here.
 */
export class ModuleHealthCheck extends ModuleBase {
  private core: SdkCore;
  private sent: boolean = false;

  private countLogWarning: number = 0;
  private countLogError: number = 0;
  private statusCode: number = -1;
  private errorMessage: string = '';
  private countBackoffRequest: number = 0;
  /** Current consecutive run. Rolled into `maxConsecutiveBackoff` on each break. */
  private consecutiveBackoffRequestCounter: number = 0;
  private maxConsecutiveBackoff: number = 0;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleHealthCheck] Initialising');
    this.core = core;
  }

  public override async onInit(): Promise<void> {
    // Restore persisted counters first so a crash+restart doesn't lose them.
    await this.loadState();

    if (this.config.disableHealthCheck) {
      this.config.logger.d('[ModuleHealthCheck] onInit, health check disabled by config — no report will be sent');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleHealthCheck] onInit, temporary device ID mode — no report this lifecycle');
      return;
    }
    // Hook the logger so warn/error logs bump the counters. The logger is
    // already set up at this point (CountlyInstance copies logging fields
    // before any module init).
    this.config.logger.setHealthListener((isError: boolean) => {
      if (isError) this.countLogError++;
      else this.countLogWarning++;
    });
    // Hook the request queue so failed requests + backoff events bump counters.
    // ArkTS strict mode bans object-literal interface implementations
    // (arkts-no-untyped-obj-literals) — use a named adapter class instead.
    this.core.requestQueue.setHealthListener(new HealthCheckQueueListener(this));

    // Defer the first send to the next macrotask. The counter snapshot inside
    // sendHealthCheck is synchronous up to its first await, so a fire-and-
    // forget call here would race with anything the integrator (or test) does
    // synchronously after init returns. With setTimeout(0), the snapshot
    // happens after the microtask queue drains, giving post-init synchronous
    // activity a chance to reach the counters first. Best-effort — a failure
    // keeps counters in storage for the next launch.
    setTimeout(() => {
      this.sendHealthCheck().catch((err: Object) => {
        this.config.logger.e(`[ModuleHealthCheck] sendHealthCheck rejected: ${err}`);
      });
    }, 0);
  }

  public override async onHalt(): Promise<void> {
    // Persist on shutdown so activity-stop / session-end lifecycle events
    // don't lose counters for unsent reports.
    await this.saveState();
  }

  // -- Counter mutators (called from Logger + RequestQueue listeners) --

  public logFailedNetworkRequest(statusCode: number, errorResponse: string): void {
    if (statusCode > 0 && statusCode < 1000) this.statusCode = statusCode;
    if (errorResponse) {
      this.errorMessage = errorResponse.length > ERROR_MESSAGE_MAX
        ? errorResponse.substring(0, ERROR_MESSAGE_MAX)
        : errorResponse;
    }
  }

  public logBackoffRequest(): void {
    this.countBackoffRequest++;
    this.consecutiveBackoffRequestCounter++;
  }

  public logConsecutiveBackoffEnd(): void {
    if (this.consecutiveBackoffRequestCounter > this.maxConsecutiveBackoff) {
      this.maxConsecutiveBackoff = this.consecutiveBackoffRequestCounter;
    }
    this.consecutiveBackoffRequestCounter = 0;
  }

  // -- Internal send --

  private async sendHealthCheck(): Promise<void> {
    if (this.sent) return;
    this.sent = true;
    // Finalize consecutive backoff before serializing.
    this.logConsecutiveBackoffEnd();

    const base: Record<string, string> = this.core.requestBuilder.baseParams();
    // Metrics contains only app version per dev guide.
    const appVersion: string = this.config.metricOverride['_app_version'] !== undefined
      ? this.config.metricOverride['_app_version']
      : DeviceInfo.collect(this.config.appVersion, this.config.metricOverride)['_app_version'];
    // ArkTS strict mode: object-literal → typed Record so JSON.stringify gets
    // a nominally-typed value rather than a free-form literal.
    const metricsObj: Record<string, string> = { '_app_version': appVersion };
    base['metrics'] = JSON.stringify(metricsObj);
    const hcObj: Record<string, Object> = {
      'el': this.countLogError,
      'wl': this.countLogWarning,
      'sc': this.statusCode,
      'em': this.errorMessage,
      'bom': this.countBackoffRequest,
      'cbom': this.maxConsecutiveBackoff
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
            await this.clearAndSave();
            this.config.logger.d('[ModuleHealthCheck] server acknowledged — counters cleared');
            return;
          }
        } catch (parseErr) {
          this.config.logger.w(`[ModuleHealthCheck] 2xx unparseable — retaining counters: ${parseErr}`);
        }
      } else {
        this.config.logger.w(`[ModuleHealthCheck] http ${res.statusCode} — retaining counters for next launch`);
      }
      // Retain on any failure path so the next launch re-sends.
      await this.saveState();
    } catch (err) {
      this.config.logger.w(`[ModuleHealthCheck] network error — retaining counters: ${err}`);
      await this.saveState();
    }
  }

  // -- Persistence --

  private async loadState(): Promise<void> {
    if (!this.config.storage) return;
    const raw: string = await this.config.storage.getString(STORAGE_KEY, '');
    if (raw.length === 0) return;
    try {
      const parsed: Object = JSON.parse(raw);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        // Malformed — reset + clear.
        await this.clearAndSave();
        return;
      }
      // Read through `Record<string, Object>` so ArkTS strict mode doesn't
      // flag a direct interface/class cast from JSON.parse output.
      const s: Record<string, Object> = parsed as Record<string, Object>;
      this.countLogError = this.safeNumber(s['LErr'] as number, 0);
      this.countLogWarning = this.safeNumber(s['LWar'] as number, 0);
      this.statusCode = this.safeNumber(s['RStatC'] as number, -1);
      this.errorMessage = s['REMsg'] ? String(s['REMsg']) : '';
      this.countBackoffRequest = this.safeNumber(s['BReq'] as number, 0);
      this.maxConsecutiveBackoff = this.safeNumber(s['CBReq'] as number, 0);
    } catch (err) {
      // Dev guide explicitly says: malformed → reset + clear.
      this.config.logger.w(`[ModuleHealthCheck] loadState, stored JSON malformed — resetting: ${err}`);
      await this.clearAndSave();
    }
  }

  private async saveState(): Promise<void> {
    if (!this.config.storage) return;
    const state: StoredState = new StoredState(
      this.countLogError,
      this.countLogWarning,
      this.statusCode,
      this.errorMessage,
      this.countBackoffRequest,
      this.maxConsecutiveBackoff
    );
    try {
      await this.config.storage.setString(STORAGE_KEY, JSON.stringify(state));
    } catch (err) {
      this.config.logger.e(`[ModuleHealthCheck] saveState, failed: ${err}`);
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
    if (this.config.storage) {
      await this.config.storage.remove(STORAGE_KEY);
    }
  }

  private safeNumber(v: number | undefined, fallback: number): number {
    return (typeof v === 'number' && Number.isFinite(v)) ? v : fallback;
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
