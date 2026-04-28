import { Logger } from '../internal/Logger';
import { ModuleViews } from '../internal/modules/ModuleViews';
import { SegmentationMap } from '../types/Types';

/** User-facing views surface — accessed via `Countly.sharedInstance().views`. */
export class ViewsApi {
  private readonly logger: Logger;
  private readonly module: ModuleViews;

  constructor(logger: Logger, module: ModuleViews) {
    this.logger = logger;
    this.module = module;
  }

  public async startAutoStoppedView(name: string, segmentation: SegmentationMap | null = null): Promise<string | null> {
    this.logger.i(`[Views] Calling startAutoStoppedView, name=[${name}]`);
    return this.module.startAutoStoppedView(name, segmentation);
  }

  public async startView(name: string, segmentation: SegmentationMap | null = null): Promise<string | null> {
    this.logger.i(`[Views] Calling startView, name=[${name}]`);
    return this.module.startView(name, segmentation);
  }

  public async stopViewWithName(name: string, segmentation: SegmentationMap | null = null): Promise<void> {
    this.logger.i(`[Views] Calling stopViewWithName, name=[${name}]`);
    await this.module.stopViewWithName(name, segmentation);
  }

  public async stopViewWithID(id: string, segmentation: SegmentationMap | null = null): Promise<void> {
    this.logger.i(`[Views] Calling stopViewWithID, id=[${id}]`);
    await this.module.stopViewWithID(id, segmentation);
  }

  public pauseViewWithID(id: string): void {
    this.logger.i(`[Views] Calling pauseViewWithID, id=[${id}]`);
    this.module.pauseViewWithID(id);
  }

  public resumeViewWithID(id: string): void {
    this.logger.i(`[Views] Calling resumeViewWithID, id=[${id}]`);
    this.module.resumeViewWithID(id);
  }

  public async stopAllViews(segmentation: SegmentationMap | null = null): Promise<void> {
    this.logger.i('[Views] Calling stopAllViews');
    await this.module.stopAllViews(segmentation);
  }

  public addSegmentationToViewWithID(id: string, segmentation: SegmentationMap): void {
    this.logger.i(`[Views] Calling addSegmentationToViewWithID, id=[${id}]`);
    this.module.addSegmentationToViewWithID(id, segmentation);
  }

  public addSegmentationToViewWithName(name: string, segmentation: SegmentationMap): void {
    this.logger.i(`[Views] Calling addSegmentationToViewWithName, name=[${name}]`);
    this.module.addSegmentationToViewWithName(name, segmentation);
  }

  public setGlobalViewSegmentation(segmentation: SegmentationMap): void {
    this.logger.i('[Views] Calling setGlobalViewSegmentation');
    this.module.setGlobalViewSegmentation(segmentation);
  }

  public updateGlobalViewSegmentation(segmentation: SegmentationMap): void {
    this.logger.i('[Views] Calling updateGlobalViewSegmentation');
    this.module.updateGlobalViewSegmentation(segmentation);
  }

  /**
   * Report a UI orientation change. Pass either `'portrait'` or
   * `'landscape'`. Typical wiring: call from your UIAbility's
   * `onConfigurationUpdate`, or from a `@ohos.display` `on('change', ...)`
   * callback — the SDK does not subscribe to display events itself to avoid
   * hard-depending on a UIAbilityContext. No-op if `trackOrientationChanges`
   * was disabled on `ViewsConfig`, if the mode is unchanged since the last
   * call, or if `users` consent is missing.
   */
  public async updateOrientation(mode: string): Promise<void> {
    this.logger.i(`[Views] Calling updateOrientation, mode=[${mode}]`);
    await this.module.updateOrientation(mode);
  }
}
