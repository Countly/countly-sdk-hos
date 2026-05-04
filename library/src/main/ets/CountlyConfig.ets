import common from '@ohos.app.ability.common';
import { Utils } from './internal/Utils';
import {
  LogLevel,
  LogListener,
  GlobalCrashFilterCallback,
  ContentCallback,
  SegmentationMap,
  MessagingProvider,
  PushTestMode,
  PushActionHandler,
  RCDownloadCallback,
  WebViewDisplayOption
} from './types/Types';

/**
 * Logging sub-config. Exposed under `CountlyConfig.logging`. The listener fires
 * for every log at or above `minLevel` — routing VERBOSE to a cloud logger is
 * a data-exfiltration hazard, so defaults to DEBUG.
 */
export class LoggingConfig {
  public enabled: boolean = false;
  public listener: LogListener | null = null;
  public minLevel: LogLevel = LogLevel.DEBUG;

  public enableLogging(): LoggingConfig { this.enabled = true; return this; }
  public setListener(listener: LogListener | null): LoggingConfig { this.listener = listener; return this; }
  public setMinLevel(level: LogLevel): LoggingConfig { this.minLevel = level; return this; }
}

/**
 * Device ID sub-config. If no custom id is set, the SDK generates a stable UUID
 * at first launch and persists it via `@ohos.data.preferences`.
 */
export class DeviceIdConfig {
  public id: string | null = null;
  public temporaryMode: boolean = false;
  public clearStored: boolean = false;

  public setId(id: string | null): DeviceIdConfig { this.id = id; return this; }
  public enableTemporaryMode(): DeviceIdConfig { this.temporaryMode = true; return this; }
  public enableClearStoredDeviceId(): DeviceIdConfig { this.clearStored = true; return this; }
}

/**
 * Consent sub-config. When `requires=true`, the SDK gates every feature on an
 * explicit consent grant. `initialAll=true` overrides `initial` and grants
 * every feature at init.
 */
export class ConsentConfig {
  public requires: boolean = false;
  public initial: string[] = [];
  public initialAll: boolean = false;

  public setRequiresConsent(requires: boolean): ConsentConfig { this.requires = requires; return this; }
  public setEnabled(featureNames: string[]): ConsentConfig {
    this.initial = featureNames.slice();
    return this;
  }
  public giveAll(): ConsentConfig { this.initialAll = true; return this; }
}

/**
 * Networking / request queue sub-config. Includes the offline-mode and
 * health-check toggles since they affect the request pipeline.
 */
export class NetworkConfig {
  public maxRequestQueueSize: number = 1000;
  // 7 days — prevents the queue from holding ancient requests on permanent
  // outages. Integrators can set 0 to disable drop-by-age entirely.
  public requestDropAgeHours: number = 168;
  public requestTimeoutSec: number = 30;
  public forcePost: boolean = true;
  public parameterTamperingSalt: string | null = null;
  public customHeaders: Record<string, string> = {};
  public backoffDisabled: boolean = false;
  public startInOfflineMode: boolean = false;
  public healthCheckDisabled: boolean = false;

  public setMaxRequestQueueSize(maxSize: number): NetworkConfig {
    this.maxRequestQueueSize = Math.max(1, maxSize);
    return this;
  }
  public setRequestDropAgeHours(hours: number): NetworkConfig {
    this.requestDropAgeHours = hours;
    return this;
  }
  public setRequestTimeoutDuration(seconds: number): NetworkConfig {
    this.requestTimeoutSec = Math.max(1, seconds);
    return this;
  }
  public setHttpPostForced(isForced: boolean): NetworkConfig {
    this.forcePost = isForced;
    return this;
  }
  public setParameterTamperingProtectionSalt(salt: string): NetworkConfig {
    this.parameterTamperingSalt = salt;
    return this;
  }
  public addCustomNetworkRequestHeaders(headers: Record<string, string>): NetworkConfig {
    const keys: string[] = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) this.customHeaders[keys[i]] = headers[keys[i]];
    return this;
  }
  public disableBackoffMechanism(): NetworkConfig {
    this.backoffDisabled = true;
    return this;
  }

  /**
   * Start the SDK in offline mode. The queue accepts enqueues but nothing is
   * sent until `disableOfflineMode(deviceId?)` is called on the instance.
   */
  public enableOfflineMode(): NetworkConfig {
    this.startInOfflineMode = true;
    return this;
  }

  /**
   * Opt out of the one-shot SDK health-check report (sent automatically at
   * init). Counters still accumulate.
   */
  public disableHealthCheck(): NetworkConfig {
    this.healthCheckDisabled = true;
    return this;
  }
}

/**
 * Sessions sub-config. Three modes: fully automatic (default), manual (host
 * drives begin/update/end), and hybrid (host drives begin/end; updates remain
 * automatic).
 */
export class SessionsConfig {
  public manualControl: boolean = false;
  public manualHybridMode: boolean = false;
  public updateIntervalSec: number = 60;

  public enableManualControl(): SessionsConfig {
    this.manualControl = true;
    return this;
  }
  public enableManualHybridMode(): SessionsConfig {
    this.manualControl = true;
    this.manualHybridMode = true;
    return this;
  }
  public setUpdateIntervalSec(sec: number): SessionsConfig {
    this.updateIntervalSec = Math.max(1, sec);
    return this;
  }
}

/**
 * Events sub-config. Only the batching threshold lives here — per-event limits
 * (max key length etc.) come from the SDK-level `Limits` class and aren't
 * intended to be user-tuned.
 */
export class EventsConfig {
  public queueThreshold: number = 100;

  public setQueueSizeToSend(threshold: number): EventsConfig {
    this.queueThreshold = Math.max(1, threshold);
    return this;
  }
}

/**
 * Crash-related sub-config. Exposed under CountlyConfig.crashes to match the
 * dev guide API shape.
 */
export class CrashesConfig {
  public enabled: boolean = false;
  public recordAllThreads: boolean = false;
  public customSegmentation: SegmentationMap = {};
  public filter: GlobalCrashFilterCallback | null = null;

  public enableCrashReporting(): CrashesConfig {
    this.enabled = true;
    return this;
  }

  public setCustomCrashSegmentation(seg: SegmentationMap): CrashesConfig {
    this.customSegmentation = seg;
    return this;
  }

  public setGlobalCrashFilterCallback(cb: GlobalCrashFilterCallback): CrashesConfig {
    this.filter = cb;
    return this;
  }

  public enableRecordAllThreadsWithCrash(): CrashesConfig {
    this.recordAllThreads = true;
    return this;
  }
}

export class ViewsConfig {
  public automaticEnabled: boolean = false;
  public useShortNames: boolean = false;
  public exclusions: string[] = [];
  public globalSegmentation: SegmentationMap = {};
  public trackOrientationChanges: boolean = true;
  public disableViewRestartForManual: boolean = false;

  public enableAutomaticViewTracking(): ViewsConfig {
    this.automaticEnabled = true;
    return this;
  }

  public enableAutomaticViewShortNames(): ViewsConfig {
    this.useShortNames = true;
    return this;
  }

  public setAutomaticViewTrackingExclusions(exclusions: string[]): ViewsConfig {
    this.exclusions = exclusions;
    return this;
  }

  public setGlobalViewSegmentation(segmentation: SegmentationMap): ViewsConfig {
    this.globalSegmentation = segmentation;
    return this;
  }

  public setTrackOrientationChanges(enabled: boolean): ViewsConfig {
    this.trackOrientationChanges = enabled;
    return this;
  }

  public disableViewRestartForManualRecording(): ViewsConfig {
    this.disableViewRestartForManual = true;
    return this;
  }
}

export class ContentConfig {
  public callback: ContentCallback | null = null;
  public zoneIntervalSec: number = 30;
  public categories: string[] = [];
  public refreshEnabled: boolean = true;
  public displayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;
  /** Extra allowed origins for postMessage-style protocol validation. The
   *  server URL is always included implicitly. */
  public allowedOrigins: string[] = [];

  public setContentCallback(cb: ContentCallback): ContentConfig {
    this.callback = cb;
    return this;
  }

  public setZoneTimerInterval(sec: number): ContentConfig {
    if (sec > 15) {
      this.zoneIntervalSec = sec;
    } else {
      // Dev guide minimum is 15s. Warn rather than silently ignore so the
      // integrator sees why their 5s interval didn't take effect.
      console.warn(`[Countly] ContentConfig setZoneTimerInterval, ${sec}s is below the 15s minimum — ignored`);
    }
    return this;
  }

  /**
   * Preset the category filter that will be sent on every content fetch
   * request. Empty array (default) means all categories.
   */
  public setCategories(categories: string[]): ContentConfig {
    this.categories = categories.slice();
    return this;
  }

  /**
   * Disable `refreshContentZone`. When false, a manual refresh is a no-op
   * (matches the "rcz" SDK behavior flag described in the dev guide).
   */
  public disableRefreshContentZone(): ContentConfig {
    this.refreshEnabled = false;
    return this;
  }

  /**
   * IMMERSIVE (default) — overlay covers the full screen including notch
   * and gesture-bar areas. SAFE_AREA — overlay respects cutout + status bar
   * + navigation-bar insets so content doesn't render behind system UI.
   */
  public setDisplayMode(option: WebViewDisplayOption): ContentConfig {
    this.displayMode = option;
    return this;
  }

  /**
   * Extend the postMessage origin whitelist beyond the Countly server URL.
   * Use this for content served from a CDN or staging origin different from
   * the analytics API origin.
   */
  public addAllowedOrigins(origins: string[]): ContentConfig {
    for (let i = 0; i < origins.length; i++) {
      if (origins[i] && this.allowedOrigins.indexOf(origins[i]) === -1) {
        this.allowedOrigins.push(origins[i]);
      }
    }
    return this;
  }
}

export class FeedbackConfig {
  public displayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;

  /**
   * IMMERSIVE (default) — feedback widget covers full screen for versioned
   * widgets. SAFE_AREA — respect cutout / status-bar insets.
   */
  public setDisplayMode(option: WebViewDisplayOption): FeedbackConfig {
    this.displayMode = option;
    return this;
  }
}

/**
 * Push notification sub-config. Exposed under CountlyConfig.push to match the
 * dev guide API shape. All fields are read during init — changing them after
 * init has no effect.
 */
export class PushConfig {
  public provider: MessagingProvider = MessagingProvider.HMS;
  public testMode: PushTestMode = PushTestMode.PRODUCTION;
  public sendTokenAlways: boolean = false;
  public actionHandler: PushActionHandler | null = null;
  public allowedIntentTargets: string[] = [];

  public setMessagingProvider(provider: MessagingProvider): PushConfig {
    this.provider = provider;
    return this;
  }

  public setTestMode(mode: PushTestMode): PushConfig {
    this.testMode = mode;
    return this;
  }

  public setSendPushTokenAlways(enabled: boolean): PushConfig {
    this.sendTokenAlways = enabled;
    return this;
  }

  public setNotificationActionHandler(handler: PushActionHandler): PushConfig {
    this.actionHandler = handler;
    return this;
  }

  /**
   * Restrict which URL schemes / prefixes can be opened when a push action is
   * tapped. Empty array = default (all URLs allowed) per dev guide. Integrators
   * should provide an allowlist to block a hostile payload from launching
   * arbitrary deep links.
   */
  public setAllowedIntentTargets(allowList: string[]): PushConfig {
    this.allowedIntentTargets = allowList.slice();
    return this;
  }
}

/**
 * Remote Config sub-config. Exposed under `CountlyConfig.remoteConfig`. The
 * class name keeps the `RC` prefix to stay aligned with the exported public
 * types `RCData` and `RCDownloadCallback`.
 */
export class RCConfig {
  public abAutoOptin: boolean = false;
  public automaticTriggers: boolean = false;
  public valueCaching: boolean = false;
  public globalCallback: RCDownloadCallback | null = null;

  /**
   * Enroll users in A/B testing on every remote-config download. Sends `oi=1`
   * (vs. default `oi=0`). Dev guide §Remote Config A/B Testing.
   */
  public enrollABonDownload(): RCConfig {
    this.abAutoOptin = true;
    return this;
  }

  /**
   * Enable automatic RC downloads on init (if not temp-mode), after a device-ID
   * change, after exiting temporary-id mode, and when remote-config consent is
   * granted post-init. Without this flag integrators must call downloadAllKeys
   * explicitly.
   */
  public enableAutomaticTriggers(): RCConfig {
    this.automaticTriggers = true;
    return this;
  }

  /**
   * On a device-ID change, keep the existing RC cache instead of wiping it —
   * each preserved value is marked stale (isCurrentUsersData=false) so callers
   * can distinguish carryover-from-previous-user from freshly-downloaded.
   */
  public enableValueCaching(): RCConfig {
    this.valueCaching = true;
    return this;
  }

  /**
   * Register a global RC download callback. Fires on every download (including
   * partial/omitting/specific) so integrators can react without holding a
   * per-call callback.
   */
  public registerGlobalCallback(callback: RCDownloadCallback): RCConfig {
    this.globalCallback = callback;
    return this;
  }
}

/**
 * Location sub-config. `disabled=true` wins over any coordinate fields — the
 * SDK sends an empty `location=` param which tells the server to erase any
 * previously stored location.
 */
export class LocationConfig {
  public country: string | null = null;
  public city: string | null = null;
  public gps: string | null = null;
  public ip: string | null = null;
  public disabled: boolean = false;

  public set(country: string | null, city: string | null, gps: string | null, ip: string | null): LocationConfig {
    this.country = country;
    this.city = city;
    this.gps = gps;
    this.ip = ip;
    return this;
  }

  public disable(): LocationConfig {
    this.disabled = true;
    return this;
  }
}

/**
 * User profile sub-config. Only the initial-props bag lives here; mutation at
 * runtime is via `Countly.sharedInstance().userProfile.setProperties(...)`.
 */
export class UserProfileConfig {
  public initialProperties: SegmentationMap = {};

  public setProperties(props: SegmentationMap): UserProfileConfig {
    this.initialProperties = props;
    return this;
  }
}

/**
 * Experimental sub-config. These features are prototype-stage per the dev
 * guide and may move into main surfaces or be removed. No stability guarantee.
 */
export class ExperimentalConfig {
  public visibilityTracking: boolean = false;
  public previousNameRecording: boolean = false;

  /**
   * Tag every recorded event/view with a `cly_v` segmentation value (1 in
   * foreground, 0 in background). Useful for correlating telemetry with app
   * lifecycle state.
   */
  public enableVisibilityTracking(): ExperimentalConfig {
    this.visibilityTracking = true;
    return this;
  }

  /**
   * Record the previous event name (`cly_pen`) and current view name
   * (`cly_cvn`) on every custom event. Adds navigation context to events.
   */
  public enablePreviousNameRecording(): ExperimentalConfig {
    this.previousNameRecording = true;
    return this;
  }
}

/**
 * Top-level SDK configuration. Every setting available before init lives here,
 * either directly (ctor args + appVersion + metricOverride) or on one of the
 * grouped sub-configs. `context` is mandatory on HarmonyOS because persistent
 * preferences require a Context handle.
 */
export class CountlyConfig {
  public context: common.Context;
  public serverUrl: string;
  public appKey: string;

  public appVersion: string = '1.0';
  public metricOverride: Record<string, string> = {};

  /**
   * Developer-supplied SDK Behavior Settings, used as the bootstrap value when
   * no persisted server settings exist yet. Plain JSON string; the same shape
   * the server returns from `/o/sdk?method=sc`. Empty / null = no bootstrap.
   *
   * Precedence (per dev guide §SDK Behavior Settings):
   *   SDK defaults < dev-set settings < dev-set behavior settings < stored.
   */
  public sdkBehaviorSettings: string | null = null;
  /**
   * When true, the SDK loads/applies stored + dev-supplied settings but never
   * fetches from `/o/sdk?method=sc`. Useful in environments where the analytics
   * server is reachable for normal traffic but the SBS endpoint is locked down.
   */
  public sdkBehaviorSettingsRequestsDisabled: boolean = false;

  public readonly logging: LoggingConfig = new LoggingConfig();
  public readonly deviceId: DeviceIdConfig = new DeviceIdConfig();
  public readonly consent: ConsentConfig = new ConsentConfig();
  public readonly network: NetworkConfig = new NetworkConfig();
  public readonly sessions: SessionsConfig = new SessionsConfig();
  public readonly events: EventsConfig = new EventsConfig();
  public readonly crashes: CrashesConfig = new CrashesConfig();
  public readonly views: ViewsConfig = new ViewsConfig();
  protected readonly content: ContentConfig = new ContentConfig();
  protected readonly feedback: FeedbackConfig = new FeedbackConfig();
  protected readonly push: PushConfig = new PushConfig();

  // Underscore prefix marks these as SDK-internal — integrators shouldn't
  // touch them (the corresponding modules are disabled). The fields stay
  // `protected` so they don't surface in autocomplete on a CountlyConfig
  // instance; CountlyInstance uses these getters to pull values during
  // init() (see CountlyInstance.applyCountlyConfig). Tests reach the same
  // state via TestableCountlyConfig.*ForTest in TestHelpers.ets.
  public get _internalContent(): ContentConfig { return this.content; }
  public get _internalFeedback(): FeedbackConfig { return this.feedback; }
  public get _internalPush(): PushConfig { return this.push; }
  public readonly remoteConfig: RCConfig = new RCConfig();
  public readonly location: LocationConfig = new LocationConfig();
  public readonly userProfile: UserProfileConfig = new UserProfileConfig();
  public readonly experimental: ExperimentalConfig = new ExperimentalConfig();

  constructor(context: common.Context, serverUrl: string, appKey: string) {
    // Validate here so misconfiguration surfaces at config-construction time,
    // not hidden inside the async init. Console.error too — the logger isn't
    // attached to this CountlyConfig until init copies it over.
    if (!appKey || appKey.trim().length === 0) {
      console.error('[Countly] CountlyConfig constructor, appKey must be non-empty');
      throw new Error('[Countly] CountlyConfig, appKey is required');
    }
    const urlReason: string = Utils.validateServerUrl(serverUrl);
    if (urlReason === 'empty') {
      console.error('[Countly] CountlyConfig constructor, serverUrl must be non-empty');
      throw new Error('[Countly] CountlyConfig, serverUrl is required');
    }
    if (urlReason === 'scheme') {
      console.error('[Countly] CountlyConfig constructor, serverUrl must start with http:// or https://');
      throw new Error('[Countly] CountlyConfig, invalid serverUrl scheme');
    }
    if (urlReason === 'authority') {
      console.error('[Countly] CountlyConfig constructor, serverUrl must not contain "@" in the authority');
      throw new Error('[Countly] CountlyConfig, serverUrl authority must not contain userinfo');
    }
    this.context = context;
    this.serverUrl = serverUrl;
    this.appKey = appKey;
  }

  public setAppVersion(v: string): CountlyConfig { this.appVersion = v; return this; }
  public setMetricOverride(metricOverride: Record<string, string>): CountlyConfig {
    this.metricOverride = metricOverride;
    return this;
  }

  /**
   * Provide an initial SDK Behavior Settings JSON object so the SDK has a
   * working configuration before the first server fetch (or on networks
   * where the SBS endpoint is unreachable). Validated + parsed at module
   * init time; an invalid string is logged and ignored. Per dev guide
   * §SDK Behavior Settings, dev-supplied settings rank below the stored
   * (last-fetched) settings.
   */
  public setSDKBehaviorSettings(sdkBehaviorSettings: string): CountlyConfig {
    if (sdkBehaviorSettings && sdkBehaviorSettings.trim().length > 0) {
      this.sdkBehaviorSettings = sdkBehaviorSettings;
    } else {
      console.warn('[Countly] CountlyConfig setSDKBehaviorSettings, empty value — ignored');
    }
    return this;
  }

  /**
   * Disable the periodic + init-time SBS fetch. The SDK still loads any
   * persisted settings and any developer-supplied ones; it just never
   * refreshes them from the server.
   */
  public disableSDKBehaviorSettingsUpdates(): CountlyConfig {
    this.sdkBehaviorSettingsRequestsDisabled = true;
    return this;
  }
}
