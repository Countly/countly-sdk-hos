import { Logger } from '../internal/Logger';
import { ModuleRequestQueue } from '../internal/modules/ModuleRequestQueue';

/**
 * User-facing request-queue surface, accessed via
 * `Countly.sharedInstance().requests`. Forwards to ModuleRequestQueue and
 * emits the same `[Countly] Calling …` log lines the corresponding
 * CountlyInstance methods used to emit, so integrator log listeners see no
 * change after the move.
 */
export class RequestQueueApi {
  private readonly logger: Logger;
  private readonly module: ModuleRequestQueue;

  constructor(logger: Logger, module: ModuleRequestQueue) {
    this.logger = logger;
    this.module = module;
  }

  public enableOfflineMode(): void {
    this.logger.i('[Countly] Calling enableOfflineMode');
    this.module.enableOfflineMode();
  }

  public async disableOfflineMode(deviceId: string | null = null): Promise<void> {
    this.logger.i(`[Countly] Calling disableOfflineMode, deviceId=[${deviceId !== null}]`);
    await this.module.disableOfflineMode(deviceId);
  }

  public async flushQueues(): Promise<void> {
    this.logger.i('[Countly] Calling flushQueues');
    await this.module.flushQueues();
  }

  public async replaceAllAppKeysInQueueWithCurrentAppKey(): Promise<void> {
    this.logger.i('[Countly] Calling replaceAllAppKeysInQueueWithCurrentAppKey');
    await this.module.replaceAllAppKeysInQueueWithCurrentAppKey();
  }

  public async removeDifferentAppKeysFromQueue(): Promise<void> {
    this.logger.i('[Countly] Calling removeDifferentAppKeysFromQueue');
    await this.module.removeDifferentAppKeysFromQueue();
  }

  public async addDirectRequest(requestParameters: Record<string, string>): Promise<void> {
    this.logger.i('[Countly] Calling addDirectRequest');
    await this.module.addDirectRequest(requestParameters);
  }

  public async recordMetrics(metricOverride: Record<string, string>): Promise<void> {
    this.logger.i('[Countly] Calling recordMetrics');
    await this.module.recordMetrics(metricOverride);
  }
}
