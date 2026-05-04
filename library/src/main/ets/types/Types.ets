export enum LogLevel {
  VERBOSE = 0,
  DEBUG = 1,
  INFO = 2,
  WARNING = 3,
  ERROR = 4
}

export enum DeviceIdType {
  DEVELOPER_SUPPLIED = 'DEVELOPER_SUPPLIED',
  SDK_GENERATED = 'SDK_GENERATED',
  TEMPORARY_ID = 'TEMPORARY_ID'
}

export enum ContentStatus {
  COMPLETED = 'COMPLETED',
  CLOSED = 'CLOSED'
}

/**
 * Wire-format consent feature names. Use hyphens, not camelCase.
 */
export class CountlyFeature {
  public static readonly SESSIONS: string = 'sessions';
  public static readonly EVENTS: string = 'events';
  public static readonly VIEWS: string = 'views';
  public static readonly LOCATION: string = 'location';
  public static readonly CRASHES: string = 'crashes';
  public static readonly USERS: string = 'users';
  public static readonly PUSH: string = 'push';
  public static readonly STAR_RATING: string = 'star-rating';
  public static readonly REMOTE_CONFIG: string = 'remote-config';
  public static readonly FEEDBACK: string = 'feedback';
  public static readonly CLICKS: string = 'clicks';
  public static readonly SCROLLS: string = 'scrolls';
  public static readonly CONTENT: string = 'content';
  public static readonly METRICS: string = 'metrics';
  public static readonly FORMS: string = 'forms';
}

export const CountlyFeatureNames: string[] = [
  CountlyFeature.SESSIONS,
  CountlyFeature.EVENTS,
  CountlyFeature.VIEWS,
  CountlyFeature.LOCATION,
  CountlyFeature.CRASHES,
  CountlyFeature.USERS,
  CountlyFeature.PUSH,
  CountlyFeature.STAR_RATING,
  CountlyFeature.REMOTE_CONFIG,
  CountlyFeature.FEEDBACK,
  CountlyFeature.CLICKS,
  CountlyFeature.SCROLLS,
  CountlyFeature.CONTENT,
  CountlyFeature.METRICS,
  CountlyFeature.FORMS
];

export type SegmentationValue = string | number | boolean | string[] | number[] | boolean[] | null;
export type SegmentationMap = Record<string, SegmentationValue>;

export type LogListener = (message: string, level: LogLevel) => void;

/**
 * One thread's stack as `{ name, stack[] }`. ArkTS isolates can't enumerate
 * each other's stacks natively, so integrators who care about Worker-thread
 * crash context supply these via `setThreadStackProvider()` — typically by
 * maintaining a registry of running Workers and calling their own recorded
 * last-known stack on demand.
 */
export interface ThreadStackEntry {
  /** Display name used in the serialised `Thread <name>` header. */
  name: string;
  /** Multi-line stack trace, newline-separated, same format as `Error.stack`. */
  stack: string;
}

/**
 * Callback that returns the integrator's currently-known non-main thread
 * stacks at crash time. Invoked only when `recordAllThreadsWithCrash` is
 * enabled. Returning an empty array is fine — it just means "I have no extra
 * stacks to contribute" and the crash will ship with the main stack only.
 */
export type ThreadStackProvider = () => ThreadStackEntry[];

/**
 * Remote Config value wrapper. `value` is the raw decoded server value;
 * `isCurrentUsersData` is false when the value came from a previous user's
 * cache (e.g. survived a device-id change with value caching enabled) and
 * true when it was freshly downloaded under the current device id.
 */
export class RCData {
  public value: Object | null;
  public isCurrentUsersData: boolean;

  constructor(value: Object | null, isCurrentUsersData: boolean) {
    this.value = value;
    this.isCurrentUsersData = isCurrentUsersData;
  }
}

/**
 * Outcome of a remote-config download — matches the dev guide's RequestResult
 * enum so integrators can switch on it without string comparisons.
 */
export enum RequestResult {
  Success = 'Success',
  NetworkIssue = 'NetworkIssue',
  Error = 'Error'
}

/**
 * Modern download callback. `fullValueUpdate` is true when every server value
 * was replaced (downloadAllKeys) and false for partial updates (downloadSpecific
 * Keys / downloadOmittingKeys).
 */
export type RCDownloadCallback = (
  result: RequestResult,
  error: string | null,
  fullValueUpdate: boolean,
  downloadedValues: Record<string, RCData>
) => void;

export type ContentCallback = (status: ContentStatus, data: Record<string, Object>) => void;

/**
 * Dimensions + coordinates (in pixels) for a single orientation of the content
 * overlay. The SDK converts dp-based server coordinates to px before handing
 * them to the integrator so the presenter doesn't need to know about density.
 */
export class ContentPlacement {
  public x: number;
  public y: number;
  public width: number;
  public height: number;

  constructor(x: number, y: number, width: number, height: number) {
    this.x = x;
    this.y = y;
    this.width = width;
    this.height = height;
  }
}

/**
 * Full parsed content payload. `html` is the content URL (named "html" for
 * server-protocol compatibility). The SDK fills whichever orientation(s) are
 * available in the server response; if only one is present, the other is
 * null. Integrators shouldn't need to construct these directly — the SDK
 * publishes them through the overlay pipeline.
 */
export class ContentData {
  public html: string;
  public portrait: ContentPlacement | null;
  public landscape: ContentPlacement | null;

  constructor(html: string, portrait: ContentPlacement | null, landscape: ContentPlacement | null) {
    this.html = html;
    this.portrait = portrait;
    this.landscape = landscape;
  }
}

/**
 * Overlay display mode.
 *
 * - IMMERSIVE: Full screen, ignores safe-area insets. Content covers notch,
 *   status bar, and navigation bar areas. Default.
 * - SAFE_AREA: Overlay respects system safe-area insets (cutout, status bar,
 *   gesture bar) so content doesn't hide behind them.
 */
export enum WebViewDisplayOption {
  IMMERSIVE = 'IMMERSIVE',
  SAFE_AREA = 'SAFE_AREA'
}

/**
 * Feedback widget types. Values match the server wire format ("nps", "survey",
 * "rating") — do not change the string values.
 */
export enum FeedbackWidgetType {
  NPS = 'nps',
  SURVEY = 'survey',
  RATING = 'rating'
}

/**
 * Server-returned description of a feedback widget. `widgetVersion` is null
 * when the server response omits `wv` — such widgets must be displayed in the
 * legacy dialog mode with an SDK-provided close button. When `widgetVersion`
 * is set, the webview handles its own close UI and should be shown fullscreen.
 */
export class CountlyFeedbackWidget {
  public widgetId: string;
  public type: FeedbackWidgetType;
  public name: string;
  public tags: string[];
  public widgetVersion: string | null;

  constructor(
    widgetId: string,
    type: FeedbackWidgetType,
    name: string,
    tags: string[],
    widgetVersion: string | null
  ) {
    this.widgetId = widgetId;
    this.type = type;
    this.name = name;
    this.tags = tags;
    this.widgetVersion = widgetVersion;
  }
}

/**
 * Callback for `getAvailableFeedbackWidgets`. `widgets` is empty (not null)
 * on error; `error` is null on success.
 */
export type RetrieveFeedbackWidgets = (widgets: CountlyFeedbackWidget[], error: string | null) => void;

/**
 * Callback for `getFeedbackWidgetData`. `data` is null on error.
 */
export type RetrieveFeedbackWidgetData = (data: Record<string, Object> | null, error: string | null) => void;

/**
 * Callback handed to `presentFeedbackWidget` (and the convenience
 * `presentNPS`/`presentSurvey`/`presentRating` wrappers). `onFinished` fires
 * on completion or error (`error` is null on success). `onClosed` fires when
 * the user dismisses the widget.
 */
export interface FeedbackCallback {
  onFinished(error: string | null): void;
  onClosed(): void;
}


/**
 * Crash data passed to the global crash filter. Setters mutate the object in
 * place. Any mutation is detected by the SDK to set the "_ob" metric.
 */
export class CrashData {
  public stackTrace: string;
  public breadcrumbs: string[];
  public crashSegmentation: SegmentationMap;
  public crashMetrics: Record<string, Object>;
  public fatal: boolean;

  constructor(
    stackTrace: string,
    breadcrumbs: string[],
    crashSegmentation: SegmentationMap,
    crashMetrics: Record<string, Object>,
    fatal: boolean
  ) {
    this.stackTrace = stackTrace;
    this.breadcrumbs = breadcrumbs;
    this.crashSegmentation = crashSegmentation;
    this.crashMetrics = crashMetrics;
    this.fatal = fatal;
  }
}

export type GlobalCrashFilterCallback = (crash: CrashData) => boolean;

/**
 * Source of a consent change. Used to decide whether to emit a consent request
 * to the server when modules react to the change.
 */
export enum ConsentChangeSource {
  DeveloperSet = 'DeveloperSet',
  DeviceIDChangedNotMerged = 'DeviceIDChangedNotMerged'
}

/**
 * Push provider identifier sent to the server as `token_provider`. On HarmonyOS
 * devices this will almost always be HMS (the system push service), but the
 * SDK accepts FCM/APN too for cross-platform integrators who route their own
 * token acquisition.
 */
export enum MessagingProvider {
  FCM = 'FCM',
  HMS = 'HMS',
  APN = 'APN'
}

/**
 * Push gateway environment. PRODUCTION is the default. DEVELOPMENT routes
 * through the sandbox push gateway; TEST_DISTRIBUTION is production gateway
 * marked as test (useful for enterprise test distributions).
 */
export enum PushTestMode {
  PRODUCTION = 0,
  DEVELOPMENT = 1,
  TEST_DISTRIBUTION = 2
}

/**
 * Custom notification-action handler. Return `true` to tell the SDK *not* to
 * open the URL itself (you handled it). Return `false` for default behavior
 * (SDK opens the URL via the platform's default URL mechanism).
 */
export type PushActionHandler = (notificationId: string, buttonIndex: number, url: string) => boolean;
