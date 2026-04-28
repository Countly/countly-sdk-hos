import { Logger } from '../internal/Logger';
import { ModuleFeedback } from '../internal/modules/ModuleFeedback';
import {
  CountlyFeedbackWidget,
  FeedbackCallback,
  RetrieveFeedbackWidgets,
  RetrieveFeedbackWidgetData
} from '../types/Types';

/**
 * User-facing feedback-widget surface — accessed via `Countly.sharedInstance().feedback`.
 *
 * DISABLED: the feedback-widgets module is intentionally turned off in this
 * build. Method bodies are no-op'd (see logs) and the property on
 * `CountlyInstance` is scoped `private`, so the surface is unreachable from
 * integrator code. The underlying `ModuleFeedback` is still constructed and
 * wired into the lifecycle fan-out so consent / device-id / halt invariants
 * stay symmetric with the rest of the SDK; only the entry points from the
 * public API and overlay are gated.
 */
export class FeedbackApi {
  private readonly logger: Logger;
  private readonly module: ModuleFeedback;

  constructor(logger: Logger, module: ModuleFeedback) {
    this.logger = logger;
    this.module = module;
  }

  public async getAvailableFeedbackWidgets(callback: RetrieveFeedbackWidgets): Promise<void> {
    this.logger.w('[Feedback] getAvailableFeedbackWidgets — feedback module is disabled, no-op');
  }

  public async getFeedbackWidgetData(widget: CountlyFeedbackWidget | null, callback: RetrieveFeedbackWidgetData): Promise<void> {
    this.logger.w('[Feedback] getFeedbackWidgetData — feedback module is disabled, no-op');
  }

  public async presentFeedbackWidget(widget: CountlyFeedbackWidget | null, callback: FeedbackCallback | null): Promise<void> {
    this.logger.w('[Feedback] presentFeedbackWidget — feedback module is disabled, no-op');
  }

  public async reportFeedbackWidgetManually(
    widget: CountlyFeedbackWidget | null,
    widgetData: Record<string, Object> | null,
    widgetResult: Record<string, Object> | null
  ): Promise<void> {
    this.logger.w('[Feedback] reportFeedbackWidgetManually — feedback module is disabled, no-op');
  }

  public async presentNPS(nameIDorTag: string | null = null, callback: FeedbackCallback | null = null): Promise<void> {
    this.logger.w('[Feedback] presentNPS — feedback module is disabled, no-op');
  }

  public async presentSurvey(nameIDorTag: string | null = null, callback: FeedbackCallback | null = null): Promise<void> {
    this.logger.w('[Feedback] presentSurvey — feedback module is disabled, no-op');
  }

  public async presentRating(nameIDorTag: string | null = null, callback: FeedbackCallback | null = null): Promise<void> {
    this.logger.w('[Feedback] presentRating — feedback module is disabled, no-op');
  }
}
