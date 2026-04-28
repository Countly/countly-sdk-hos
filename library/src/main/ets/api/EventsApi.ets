import { Logger } from '../internal/Logger';
import { ModuleEvents } from '../internal/modules/ModuleEvents';
import { SegmentationMap } from '../types/Types';

/**
 * User-facing events surface — accessed via `Countly.sharedInstance().events`.
 * Forwards to ModuleEvents and emits the same `[Events] Calling …` log lines
 * that previously lived on CountlyInstance, so log listeners see no change.
 */
export class EventsApi {
  private readonly logger: Logger;
  private readonly module: ModuleEvents;

  constructor(logger: Logger, module: ModuleEvents) {
    this.logger = logger;
    this.module = module;
  }

  public async recordEvent(
    key: string,
    segmentation: SegmentationMap | null = null,
    count: number = 1,
    sum: number = 0,
    dur: number = 0
  ): Promise<void> {
    this.logger.i(`[Events] Calling recordEvent, key=[${key}]`);
    await this.module.recordEvent(key, segmentation, count, sum, dur);
  }

  /**
   * Record an event that occurred in the past. `timestamp` is a unix time in
   * milliseconds. Use this when flushing events from an integrator-owned
   * buffer (e.g. offline queue) so the original wall-clock time is preserved
   * instead of being replaced with "now".
   */
  public async recordPastEvent(
    key: string,
    segmentation: SegmentationMap | null,
    count: number,
    sum: number,
    dur: number,
    timestamp: number
  ): Promise<void> {
    this.logger.i(`[Events] Calling recordPastEvent, key=[${key}] timestamp=[${timestamp}]`);
    await this.module.recordPastEvent(key, segmentation, count, sum, dur, timestamp);
  }

  public startEvent(key: string): void {
    this.logger.i(`[Events] Calling startEvent, key=[${key}]`);
    this.module.startEvent(key);
  }

  public cancelEvent(key: string): void {
    this.logger.i(`[Events] Calling cancelEvent, key=[${key}]`);
    this.module.cancelEvent(key);
  }

  public async endEvent(
    key: string,
    segmentation: SegmentationMap | null = null,
    count: number = 1,
    sum: number = 0
  ): Promise<void> {
    this.logger.i(`[Events] Calling endEvent, key=[${key}]`);
    await this.module.endEvent(key, segmentation, count, sum);
  }
}
