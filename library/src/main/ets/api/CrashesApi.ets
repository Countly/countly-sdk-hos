import { Logger } from '../internal/Logger';
import { ModuleCrashes } from '../internal/modules/ModuleCrashes';
import { SegmentationMap, ThreadStackProvider } from '../types/Types';

/** User-facing crashes surface, accessed via `Countly.sharedInstance().crashes`. */
export class CrashesApi {
  private readonly logger: Logger;
  private readonly module: ModuleCrashes;

  constructor(logger: Logger, module: ModuleCrashes) {
    this.logger = logger;
    this.module = module;
  }

  public addCrashBreadcrumb(record: string): void {
    this.logger.i('[Crashes] Calling addCrashBreadcrumb');
    this.module.addBreadcrumb(record);
  }

  public async recordHandledException(err: Error, customSegmentation: SegmentationMap | null = null): Promise<void> {
    this.logger.i('[Crashes] Calling recordHandledException');
    await this.module.recordHandledException(err, customSegmentation);
  }

  public async recordUnhandledException(err: Error, customSegmentation: SegmentationMap | null = null): Promise<void> {
    this.logger.i('[Crashes] Calling recordUnhandledException');
    await this.module.recordUnhandledException(err, customSegmentation);
  }

  /**
   * Register a provider that returns Worker/background-thread stacks at
   * crash time. Only consulted when `recordAllThreadsWithCrash` is enabled
   * on `ConfigCrashes`. Pass `null` to clear a previous registration.
   *
   * ArkTS isolates cannot enumerate each other's stacks from the main
   * thread, so the SDK can't populate these automatically, typical wiring:
   *
   *   const workerStacks = new Map<string, string>();
   *   // each Worker reports its last-known stack back to the host via
   *   // postMessage; the host keeps the map up to date.
   *   countly.crashes.setThreadStackProvider(() =>
   *     Array.from(workerStacks.entries()).map(([name, stack]) => ({name, stack}))
   *   );
   */
  public setThreadStackProvider(provider: ThreadStackProvider | null): void {
    this.logger.i(`[Crashes] Calling setThreadStackProvider, provider=[${provider !== null}]`);
    this.module.setThreadStackProvider(provider);
  }
}
