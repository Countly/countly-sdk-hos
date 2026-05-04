import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { ModuleConsent } from './ModuleConsent';
import { ModuleEvents } from './ModuleEvents';
import { ModuleDeviceId } from './ModuleDeviceId';
import { DeviceInfo } from '../DeviceInfo';
import { Utils } from '../Utils';

const DIRECT_REQUEST_RESERVED_KEYS: string[] = [
  'app_key', 'hour', 'dow', 'tz',
  'sdk_version', 'sdk_name',
  'device_id', 'old_device_id',
  'checksum', 'checksum256'
];

/**
 * Owns the integration-wide queue operations: offline mode, queue flushing,
 * app-key rewrites, direct request injection, and the standalone metrics
 * request. The underlying RequestQueue infrastructure (FIFO + processor) is
 * still owned by CountlyInstance via SdkCore — this module is the policy
 * layer that decides when/how to mutate it.
 *
 * Surface includes integration-wide queue policy methods (offline mode,
 * flush, app-key rewrite, direct request) plus the standalone metrics
 * request.
 */
export class ModuleRequestQueue extends ModuleBase {
  private core: SdkCore;
  private consentModule: ModuleConsent;
  private eventsModule: ModuleEvents;
  private deviceIdModule: ModuleDeviceId;

  constructor(
    config: InternalConfig,
    core: SdkCore,
    consentModule: ModuleConsent,
    eventsModule: ModuleEvents,
    deviceIdModule: ModuleDeviceId
  ) {
    super(config);
    this.config.logger.v('[ModuleRequestQueue] Initialising');
    this.core = core;
    this.consentModule = consentModule;
    this.eventsModule = eventsModule;
    this.deviceIdModule = deviceIdModule;
  }

  /**
   * Pause outbound traffic. `enqueue` still works and persists to storage, but
   * nothing ships to the server until `disableOfflineMode(...)` is called.
   */
  public enableOfflineMode(): void {
    if (this.core.requestQueue.isPaused()) {
      this.config.logger.d('[ModuleRequestQueue] enableOfflineMode, already paused');
      return;
    }
    this.core.requestQueue.pause();
    this.config.logger.i('[ModuleRequestQueue] enableOfflineMode, request queue paused — no network traffic until disableOfflineMode()');
  }

  /**
   * Resume outbound traffic. If `deviceId` is non-null, it's applied before
   * the queue drains — matches the dev-guide pattern where integrators defer
   * identity assignment until after a consent dialog while staying offline.
   */
  public async disableOfflineMode(deviceId: string | null = null): Promise<void> {
    if (deviceId !== null && deviceId.length > 0) {
      await this.deviceIdModule.setID(deviceId);
    }
    this.core.requestQueue.resume();
    this.config.logger.i('[ModuleRequestQueue] disableOfflineMode, request queue resumed');
  }

  /**
   * Drop both the request queue and the event queue. Started timed events are
   * intentionally preserved. Use with caution — pending telemetry is lost.
   */
  public async flushQueues(): Promise<void> {
    this.eventsModule.clearEventQueue();
    await this.core.requestQueue.clear();
  }

  /**
   * Rewrite queued requests to use the current `app_key`. Use after changing
   * the app key so old-app-key traffic gets re-associated.
   */
  public async replaceAllAppKeysInQueueWithCurrentAppKey(): Promise<void> {
    await this.core.requestQueue.replaceAllAppKeysWithCurrent();
  }

  /** Drop queued requests that carry an app_key other than the current one. */
  public async removeDifferentAppKeysFromQueue(): Promise<void> {
    await this.core.requestQueue.removeDifferentAppKeys();
  }

  /**
   * Add a raw request directly to the queue. Honors consent: if consent is
   * required and no feature has consent, the request is dropped. Keys/values
   * are URL-encoded by the SDK — do not pre-encode. Attempts to override
   * any reserved key (see DIRECT_REQUEST_RESERVED_KEYS) are logged and ignored.
   * The wire request carries `&dr=1` so server-side analytics can distinguish
   * direct requests from SDK-emitted ones.
   */
  public async addDirectRequest(requestParameters: Record<string, string>): Promise<void> {
    if (this.config.requiresConsent && !this.consentModule.hasAnyConsent()) {
      this.config.logger.v('[ModuleRequestQueue] addDirectRequest, requires consent and no feature has consent — dropped');
      return;
    }
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    const keys: string[] = Object.keys(requestParameters);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      // Explicit denylist: base params (app_key, device_id, hour/dow/tz,
      // sdk_*) plus security-sensitive merge/integrity fields (old_device_id,
      // checksum, checksum256). `timestamp` is intentionally NOT reserved —
      // developers can override it for backfill scenarios.
      if (DIRECT_REQUEST_RESERVED_KEYS.indexOf(k) !== -1) {
        this.config.logger.w(`[ModuleRequestQueue] addDirectRequest, cannot override reserved key '${k}' — skipped`);
        continue;
      }
      params[k] = requestParameters[k];
    }
    params['dr'] = '1';
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
  }

  /**
   * Send a one-off `/i` request with the standard device metrics bag plus any
   * caller-provided overrides. Requires the `metrics` consent.
   */
  public async recordMetrics(metricOverride: Record<string, string>): Promise<void> {
    if (!this.core.consentModule.hasConsent('metrics')) return;
    const base: Record<string, string> = this.core.requestBuilder.baseParams();
    const metrics: Record<string, string> = DeviceInfo.collect(this.config.appVersion, this.config.metricOverride);
    const keys: string[] = Object.keys(metricOverride);
    for (let i = 0; i < keys.length; i++) metrics[keys[i]] = metricOverride[keys[i]];
    base['metrics'] = JSON.stringify(metrics);
    const body: string = Utils.buildQueryString(base);
    await this.core.requestQueue.enqueue(body);
  }
}
