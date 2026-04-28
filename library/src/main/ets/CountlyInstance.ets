import { CountlyConfig } from './CountlyConfig';
import { InternalConfig } from './internal/InternalConfig';
import { Storage } from './internal/Storage';
import { Network } from './internal/Network';
import { SdkCore } from './internal/SdkCore';
import { RequestBuilder } from './internal/RequestBuilder';
import { RequestQueue } from './internal/RequestQueue';
import { ModuleConsent } from './internal/modules/ModuleConsent';
import { ModuleDeviceId } from './internal/modules/ModuleDeviceId';
import { ModuleEvents, ViewIds } from './internal/modules/ModuleEvents';
import { ModuleSessions } from './internal/modules/ModuleSessions';
import { ModuleViews } from './internal/modules/ModuleViews';
import { ModuleCrashes } from './internal/modules/ModuleCrashes';
import { ModuleUserProfile } from './internal/modules/ModuleUserProfile';
import { ModuleLocation } from './internal/modules/ModuleLocation';
import { ModuleRemoteConfig } from './internal/modules/ModuleRemoteConfig';
import { ModulePush } from './internal/modules/ModulePush';
import { ModuleContent } from './internal/modules/ModuleContent';
import { ModuleFeedback } from './internal/modules/ModuleFeedback';
import { OverlayStore } from './internal/OverlayStore';
import { WindowImmersive } from './internal/WindowImmersive';
import { LifecycleObserver } from './internal/LifecycleObserver';
import { ModuleHealthCheck } from './internal/modules/ModuleHealthCheck';
import { ModuleRequestQueue } from './internal/modules/ModuleRequestQueue';
import { ModuleConfiguration } from './internal/modules/ModuleConfiguration';
import { Utils } from './internal/Utils';
import { EventsApi } from './api/EventsApi';
import { SessionsApi } from './api/SessionsApi';
import { ViewsApi } from './api/ViewsApi';
import { CrashesApi } from './api/CrashesApi';
import { UserProfileApi } from './api/UserProfileApi';
import { ConsentApi } from './api/ConsentApi';
import { DeviceIdApi } from './api/DeviceIdApi';
import { LocationApi } from './api/LocationApi';
import { RemoteConfigApi } from './api/RemoteConfigApi';
import { PushApi } from './api/PushApi';
import { ContentApi } from './api/ContentApi';
import { FeedbackApi } from './api/FeedbackApi';
import { RequestQueueApi } from './api/RequestQueueApi';
import { ModuleBase } from './internal/ModuleBase';
import {
  ConsentChangeSource,
  ContentStatus,
  DeviceIdType,
  SegmentationMap
} from './types/Types';
import display from '@ohos.display';
import { Configuration as SystemConfig } from '@ohos.app.ability.Configuration';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';

/**
 * Pairs a module instance with the short label used in rejection-log tags
 * (e.g. `events.consentWillChange`). The fan-out arrays below are listed
 * explicitly per fan-out so it's grep-able which modules participate in
 * which event — `userProfile` is a deliberate consent recipient but not a
 * device-id recipient, `configuration` is the inverse, etc.
 */
class LabeledModule {
  module: ModuleBase;
  label: string;
  constructor(module: ModuleBase, label: string) {
    this.module = module;
    this.label = label;
  }
}

/**
 * A single Countly instance. Multiple can exist simultaneously (multi-
 * instance). Each owns an InternalConfig, its own storage prefix, and a full
 * set of modules; there is no shared mutable state between instances.
 *
 * User-facing APIs are grouped under per-feature sub-namespaces:
 *   countly.events.recordEvent(...)
 *   countly.sessions.beginSession()
 *   countly.userProfile.setProperties({...})
 *   countly.requests.flushQueues() / addDirectRequest(...) / recordMetrics(...)
 * etc. Cross-module integration concerns that don't fit a single feature
 * (server URL, setExternalUrlOpener, overlay callbacks, lifecycle) remain
 * directly on this class.
 */
export class CountlyInstance implements SdkCore {
  public config: InternalConfig;
  public requestBuilder: RequestBuilder;
  public requestQueue: RequestQueue;

  /** @internal — module-to-module reads only (see SdkCore). User-facing reads
   * live on `consent` / `deviceId` facades; this field exists solely so
   * other modules can call `core.consentModule.hasConsent(...)`. */
  public readonly consentModule: ModuleConsent;
  /** @internal — see consentModule note. */
  public readonly deviceIdModule: ModuleDeviceId;
  private eventsModule: ModuleEvents;
  private sessionsModule: ModuleSessions;
  private viewsModule: ModuleViews;
  private crashesModule: ModuleCrashes;
  private readonly userProfileModule: ModuleUserProfile;
  private locationModule: ModuleLocation;
  private remoteConfigModule: ModuleRemoteConfig;
  private pushModule: ModulePush;
  private contentModule: ModuleContent;
  private feedbackModule: ModuleFeedback;
  private healthCheckModule: ModuleHealthCheck;
  /**
   * Per-instance HarmonyOS `applicationStateChange` subscription. Each
   * instance owns its own — multiple instances each get their own
   * subscription that fans into THAT instance's lifecycle methods. Halt
   * unsubscribes only this instance's observer.
   */
  private lifecycleObserver: LifecycleObserver;
  private requestQueueModule: ModuleRequestQueue;
  private readonly configurationModule: ModuleConfiguration;
  private initialized: boolean = false;

  // Fan-out lists for consent-change and device-id-change events. Initialised
  // at the end of the constructor once every module is wired. Each list is
  // separate (rather than reusing one array with conditional skips) so that a
  // future reader can grep for "which modules see consent" / "which modules
  // see device-id changes (merged vs not-merged)" and read the answer off one
  // place. Notable membership rules:
  //   - userProfile: in consent fan-outs, NOT in device-id fan-outs.
  //   - configuration: in deviceIdNotMerged only.
  private consentRecipients: LabeledModule[] = [];
  private deviceIdMergedRecipients: LabeledModule[] = [];
  private deviceIdNotMergedRecipients: LabeledModule[] = [];

  // -- User-facing per-module API surfaces --
  public readonly events: EventsApi;
  public readonly sessions: SessionsApi;
  public readonly views: ViewsApi;
  public readonly crashes: CrashesApi;
  public readonly userProfile: UserProfileApi;
  public readonly consent: ConsentApi;
  public readonly deviceId: DeviceIdApi;
  public readonly location: LocationApi;
  public readonly remoteConfig: RemoteConfigApi;
  public readonly requests: RequestQueueApi;
  // Push, content, and feedback are intentionally `private` — these modules
  // are disabled in this build. The facades are still constructed (so the
  // module lifecycle, consent fan-out, and device-id fan-out stay symmetric
  // with the rest of the SDK), but they are unreachable from integrator
  // code. Re-enable: (1) flip these back to `public readonly`, (2) unwind
  // the no-op bodies in PushApi/ContentApi/FeedbackApi, (3) restore the
  // delegating bodies of the six overlay handlers further down in this
  // file, and (4) restore the API/overlay re-exports in `library/Index.ets`.
  private readonly push: PushApi;
  private readonly content: ContentApi;
  private readonly feedback: FeedbackApi;

  constructor(countlyConfig: CountlyConfig, storageOverride?: Storage, networkOverride?: Network) {
    if (Utils.isNullOrEmpty(countlyConfig.serverUrl) || !Utils.isValidUrl(countlyConfig.serverUrl)) {
      throw new Error('[Countly] init, invalid server URL');
    }
    if (Utils.isNullOrEmpty(countlyConfig.appKey)) {
      throw new Error('[Countly] init, missing app_key');
    }

    this.config = new InternalConfig();
    this.config.serverUrl = Utils.stripTrailingSlashes(countlyConfig.serverUrl);
    this.config.appKey = countlyConfig.appKey;
    this.config.appVersion = countlyConfig.appVersion;
    this.config.context = countlyConfig.context;

    this.config.logger.setEnabled(countlyConfig.logging.enabled);
    this.config.logger.setListener(countlyConfig.logging.listener);
    this.config.logger.setMinLevel(countlyConfig.logging.minLevel);

    this.config.customDeviceId = countlyConfig.deviceId.id;
    this.config.startInTemporaryIdMode = countlyConfig.deviceId.temporaryMode;
    this.config.clearStoredDeviceId = countlyConfig.deviceId.clearStored;

    this.config.requiresConsent = countlyConfig.consent.requires;
    this.config.initialConsent = countlyConfig.consent.initial.slice();
    this.config.initialConsentAll = countlyConfig.consent.initialAll;

    this.config.eventQueueThreshold = countlyConfig.events.queueThreshold;
    this.config.maxRequestQueueSize = countlyConfig.network.maxRequestQueueSize;
    this.config.sessionUpdateIntervalSec = countlyConfig.sessions.updateIntervalSec;
    this.config.requestDropAgeHours = countlyConfig.network.requestDropAgeHours;
    this.config.parameterTamperingSalt = countlyConfig.network.parameterTamperingSalt;
    this.config.backoffEnabled = !countlyConfig.network.backoffDisabled;

    this.config.manualSessionControl = countlyConfig.sessions.manualControl;
    this.config.manualSessionHybridMode = countlyConfig.sessions.manualHybridMode;

    // Clone collections so post-construction mutation of the user-supplied
    // CountlyConfig cannot retroactively affect an already-built instance.
    // Arrays use .slice(); records use Utils.clone* helpers (ArkTS bans
    // Object.assign under arkts-limited-stdlib).
    this.config.metricOverride = Utils.cloneStringRecord(countlyConfig.metricOverride);
    this.config.initialUserProperties = Utils.cloneSegmentationMap(countlyConfig.userProfile.initialProperties);
    this.config.remoteConfigABAutoOptin = countlyConfig.remoteConfig.abAutoOptin;
    this.config.remoteConfigAutomaticTriggers = countlyConfig.remoteConfig.automaticTriggers;
    this.config.remoteConfigValueCaching = countlyConfig.remoteConfig.valueCaching;
    this.config.remoteConfigGlobalCallback = countlyConfig.remoteConfig.globalCallback;
    this.config.startInOfflineMode = countlyConfig.network.startInOfflineMode;

    this.config.initialLocationCountry = countlyConfig.location.country;
    this.config.initialLocationCity = countlyConfig.location.city;
    this.config.initialLocationGps = countlyConfig.location.gps;
    this.config.initialLocationIp = countlyConfig.location.ip;
    this.config.locationDisabled = countlyConfig.location.disabled;

    this.config.enableCrashReporting = countlyConfig.crashes.enabled;
    this.config.recordAllThreadsWithCrash = countlyConfig.crashes.recordAllThreads;
    this.config.customCrashSegmentation = Utils.cloneSegmentationMap(countlyConfig.crashes.customSegmentation);
    this.config.crashFilter = countlyConfig.crashes.filter;

    this.config.automaticViewTracking = countlyConfig.views.automaticEnabled;
    this.config.automaticViewShortNames = countlyConfig.views.useShortNames;
    this.config.autoViewExclusions = countlyConfig.views.exclusions.slice();
    this.config.globalViewSegmentation = Utils.cloneSegmentationMap(countlyConfig.views.globalSegmentation);
    this.config.trackOrientationChanges = countlyConfig.views.trackOrientationChanges;
    this.config.disableViewRestartForManual = countlyConfig.views.disableViewRestartForManual;

    this.config.contentCallback = countlyConfig._internalContent.callback;
    this.config.contentZoneInterval = countlyConfig._internalContent.zoneIntervalSec;
    this.config.contentCategories = countlyConfig._internalContent.categories.slice();
    this.config.refreshContentZoneEnabled = countlyConfig._internalContent.refreshEnabled;
    this.config.contentDisplayMode = countlyConfig._internalContent.displayMode;
    this.config.contentAllowedOrigins = countlyConfig._internalContent.allowedOrigins.slice();

    this.config.feedbackDisplayMode = countlyConfig._internalFeedback.displayMode;

    this.config.pushProvider = countlyConfig._internalPush.provider;
    this.config.pushTestMode = countlyConfig._internalPush.testMode;
    this.config.pushSendTokenAlways = countlyConfig._internalPush.sendTokenAlways;
    this.config.pushActionHandler = countlyConfig._internalPush.actionHandler;
    this.config.pushAllowedIntentTargets = countlyConfig._internalPush.allowedIntentTargets.slice();

    this.config.disableHealthCheck = countlyConfig.network.healthCheckDisabled;
    this.config.sdkBehaviorSettings = countlyConfig.sdkBehaviorSettings;
    this.config.sdkBehaviorSettingsRequestsDisabled = countlyConfig.sdkBehaviorSettingsRequestsDisabled;
    this.config.experimentalVisibilityTracking = countlyConfig.experimental.visibilityTracking;
    this.config.experimentalPreviousNameRecording = countlyConfig.experimental.previousNameRecording;

    this.config.network = networkOverride ? networkOverride : new Network(this.config.logger);
    this.config.network.setTimeoutSeconds(countlyConfig.network.requestTimeoutSec);
    this.config.network.setForcePost(countlyConfig.network.forcePost);
    this.config.network.setCustomHeaders(countlyConfig.network.customHeaders);

    this.config.storage = storageOverride ? storageOverride : new Storage(this.config.logger, this.config.appKey);

    // Wire dependencies
    this.deviceIdModule = new ModuleDeviceId(this.config, this);
    this.requestBuilder = new RequestBuilder(
      this.config,
      (): string => this.deviceIdModule.getId(),
      (): DeviceIdType => this.deviceIdModule.getType()
    );
    this.requestQueue = new RequestQueue(this.config, (): boolean => this.deviceIdModule.isTemporary());
    // Configuration module is constructed early so that any feature module
    // reading e.g. `config.eventQueueThreshold`, `config.limits.*`, or
    // `config.requiresConsent` at construction time gets the post-applied
    // (dev-supplied) values. Stored SBS is read async in `init()` before
    // any other module's `onInit`; dev-supplied SBS applies synchronously
    // here so it covers downstream module constructors too.
    this.configurationModule = new ModuleConfiguration(this.config, this);
    this.configurationModule.applyDevSuppliedSettings();
    this.consentModule = new ModuleConsent(this.config, this);

    this.eventsModule = new ModuleEvents(this.config, this);
    if (this.config.experimentalVisibilityTracking) this.eventsModule.enableVisibilityTracking();
    if (this.config.experimentalPreviousNameRecording) this.eventsModule.enablePreviousNameRecording();
    this.viewsModule = new ModuleViews(this.config, this, this.eventsModule);
    this.eventsModule.setViewIdProvider((): ViewIds => this.viewsModule.getIds());

    this.sessionsModule = new ModuleSessions(this.config, this);
    this.sessionsModule.setFirstViewFlagHost(this.viewsModule.getFirstViewFlagHost());
    // Orientation baseline at session begin — Android parity with
    // sdk/ModuleSessions.java:67-68. Gated on `trackOrientationChanges`
    // AND on the lifecycle observer being registered: tests use a fake
    // `{}` context that fails registration, and we don't want test-driven
    // beginSession calls to accumulate phantom orientation events from a
    // display read that may not be meaningful in the harness. forceSend=true
    // bypasses the dedupe so every begin_session emits a fresh baseline.
    this.sessionsModule.setOrientationBaselineEmitter((): void => {
      if (this.config.trackOrientationChanges && this.lifecycleObserver.isRegistered()) {
        this.maybeUpdateOrientationFromDisplay(true);
      }
    });

    this.crashesModule = new ModuleCrashes(this.config, this);
    this.userProfileModule = new ModuleUserProfile(this.config, this);
    this.locationModule = new ModuleLocation(this.config, this);
    this.locationModule.setSessionStartedProvider((): boolean => this.sessionsModule.isSessionActive());
    this.remoteConfigModule = new ModuleRemoteConfig(this.config, this);
    this.pushModule = new ModulePush(this.config, this);
    // Push actions flow through ModuleEvents so per-feature consent, event
    // queue batching, and immediate-flush semantics apply uniformly.
    this.pushModule.setPushActionRecorder(async (seg: SegmentationMap): Promise<void> => {
      await this.eventsModule.recordEvent('[CLY]_push_action', seg, 1, 0, 0);
    });

    this.contentModule = new ModuleContent(this.config, this);
    this.feedbackModule = new ModuleFeedback(this.config, this);
    // Feedback widget results must reach the server promptly (dev guide
    // §5351). For `[CLY]_nps` and `[CLY]_survey`, ModuleEvents'
    // IMMEDIATE_FLUSH_KEYS already force-flushes inside `recordEvent`, so no
    // extra work is needed here. For `[CLY]_star_rating` ModuleEvents
    // deliberately does NOT auto-flush — dev guide §1482 says legacy star
    // rating recordings from other paths must not trigger an immediate flush.
    // The explicit flush below covers only the feedback Rating widget path
    // without affecting those legacy recordings. A future change that adds
    // `[CLY]_star_rating` to IMMEDIATE_FLUSH_KEYS would double-flush here —
    // harmless but a sign to delete this branch.
    this.feedbackModule.setFeedbackEventRecorder(async (key: string, seg: SegmentationMap): Promise<void> => {
      await this.eventsModule.recordEvent(key, seg, 1, 0, 0);
      if (key === '[CLY]_star_rating') {
        await this.eventsModule.flushEventQueue();
      }
    });

    // Content-emitted events ride the same pipeline so consent is respected
    // and the events join any in-flight batch. The queue flush afterwards
    // matches Android (ContentOverlayView.java:620): content actions are
    // short-lived interactions we want to surface quickly.
    this.contentModule.setContentEventRecorder(async (key: string, seg: SegmentationMap): Promise<void> => {
      await this.eventsModule.recordEvent(key, seg, 1, 0, 0);
    });
    this.contentModule.setQueueFlusher(async (): Promise<void> => {
      await this.eventsModule.flushEventQueue();
    });
    // Dev guide §Display Behavior: content overlay must not be shown if
    // a feedback widget is currently displayed. The modules coordinate
    // through this callback rather than a direct reference (keeps the module
    // graph acyclic and easier to test).
    this.contentModule.setFeedbackShowingProvider((): boolean => this.feedbackModule.isShowing());

    this.healthCheckModule = new ModuleHealthCheck(this.config, this);
    // Auto-view tracking is wired via the abilityLifecycle subscription
    // ONLY when the integrator opted in via `enableAutomaticViewTracking()`.
    // Auto-orientation tracking is wired via the environment subscription
    // ONLY when `trackOrientationChanges` is on (default true). Passing
    // `null` for either keeps LifecycleObserver from subscribing to that
    // channel at all — saves a platform callback per ability/config event.
    const autoViewCallback: ((shortName: string, fullName: string) => void) | null =
      this.config.automaticViewTracking
        ? (shortName: string, fullName: string): void => this.handleAutoTrackedAbilityForeground(shortName, fullName)
        : null;
    const autoOrientationCallback: ((cfg: SystemConfig) => void) | null =
      this.config.trackOrientationChanges
        ? (cfg: SystemConfig): void => this.handleConfigurationUpdated(cfg)
        : null;
    this.lifecycleObserver = new LifecycleObserver(
      this.config.logger,
      (): void => this.lifecycleForeground(),
      (): void => this.lifecycleBackground(),
      autoViewCallback,
      autoOrientationCallback
    );
    this.requestQueueModule = new ModuleRequestQueue(
      this.config,
      this,
      this.consentModule,
      this.eventsModule,
      this.deviceIdModule
    );

    // -- Build user-facing API facades.  Each takes only the module(s) it
    // needs; this keeps internal modules private to CountlyInstance and lets
    // the facades be tested in isolation if/when we add unit tests.
    this.events = new EventsApi(this.config.logger, this.eventsModule);
    this.sessions = new SessionsApi(this.config.logger, this.sessionsModule);
    this.views = new ViewsApi(this.config.logger, this.viewsModule);
    this.crashes = new CrashesApi(this.config.logger, this.crashesModule);
    this.userProfile = new UserProfileApi(this.config.logger, this.userProfileModule);
    this.consent = new ConsentApi(this.config.logger, this.consentModule);
    this.deviceId = new DeviceIdApi(this.config.logger, this.deviceIdModule);
    this.location = new LocationApi(this.config.logger, this.locationModule);
    this.remoteConfig = new RemoteConfigApi(this.config.logger, this.remoteConfigModule);
    this.push = new PushApi(
      this.config.logger,
      this.pushModule,
      (feature: string): boolean => this.consentModule.hasConsent(feature)
    );
    this.content = new ContentApi(this.config.logger, this.contentModule);
    this.feedback = new FeedbackApi(this.config.logger, this.feedbackModule);
    this.requests = new RequestQueueApi(this.config.logger, this.requestQueueModule);

    // Device-ID change fan-out: when the device ID changes, every module
    // needs a chance to react. Without-merge is a user switch (clear timed
    // events, breadcrumbs, RC cache, consent, end + begin session). With-merge
    // keeps state — modules are notified separately so they can do bookkeeping.
    this.consentRecipients = [
      new LabeledModule(this.eventsModule, 'events'),
      new LabeledModule(this.viewsModule, 'views'),
      new LabeledModule(this.sessionsModule, 'sessions'),
      new LabeledModule(this.crashesModule, 'crashes'),
      new LabeledModule(this.locationModule, 'location'),
      new LabeledModule(this.userProfileModule, 'userProfile'),
      new LabeledModule(this.remoteConfigModule, 'remoteConfig'),
      new LabeledModule(this.pushModule, 'push'),
      new LabeledModule(this.contentModule, 'content'),
      new LabeledModule(this.feedbackModule, 'feedback')
    ];
    this.deviceIdMergedRecipients = [
      new LabeledModule(this.eventsModule, 'events'),
      new LabeledModule(this.viewsModule, 'views'),
      new LabeledModule(this.sessionsModule, 'sessions'),
      new LabeledModule(this.crashesModule, 'crashes'),
      new LabeledModule(this.locationModule, 'location'),
      new LabeledModule(this.remoteConfigModule, 'remoteConfig'),
      new LabeledModule(this.pushModule, 'push'),
      new LabeledModule(this.contentModule, 'content'),
      new LabeledModule(this.feedbackModule, 'feedback')
    ];
    this.deviceIdNotMergedRecipients = [
      new LabeledModule(this.eventsModule, 'events'),
      new LabeledModule(this.viewsModule, 'views'),
      new LabeledModule(this.sessionsModule, 'sessions'),
      new LabeledModule(this.crashesModule, 'crashes'),
      new LabeledModule(this.locationModule, 'location'),
      new LabeledModule(this.remoteConfigModule, 'remoteConfig'),
      new LabeledModule(this.pushModule, 'push'),
      new LabeledModule(this.contentModule, 'content'),
      new LabeledModule(this.feedbackModule, 'feedback'),
      new LabeledModule(this.configurationModule, 'configuration')
    ];

    this.deviceIdModule.setChangeListener(async (oldId: string, newId: string, merged: boolean): Promise<void> => {
      if (merged) {
        const promises: Promise<void>[] = this.deviceIdMergedRecipients.map((lm: LabeledModule): Promise<void> =>
          this.captureRejection(`${lm.label}.onDeviceIdChangedMerged`, lm.module.onDeviceIdChangedMerged(oldId, newId))
        );
        await Promise.all(promises);
      } else {
        // Reset consent FIRST so modules reacting to the deviceId change see
        // consent already cleared (they may skip enqueue decisions on that).
        await this.consentModule.resetForDeviceIdChangeNotMerged();
        const promises: Promise<void>[] = this.deviceIdNotMergedRecipients.map((lm: LabeledModule): Promise<void> =>
          this.captureRejection(`${lm.label}.onDeviceIdChangedNotMerged`, lm.module.onDeviceIdChangedNotMerged(oldId, newId))
        );
        await Promise.all(promises);
      }
    });
  }

  public async init(): Promise<void> {
    if (this.initialized) {
      // Log at ERROR: a second init() against an already-initialized instance
      // means the integrator expected a different config to take effect and
      // it silently won't. Only `Countly.initShared` short-circuits by
      // design; if you reach *this* path you almost certainly have a bug.
      this.config.logger.e('[Countly] init, already initialized — ignoring (check for duplicate init() calls)');
      return;
    }
    this.initialized = true;

    // Register the lifecycle observer SYNCHRONOUSLY before any await below
    // yields control. HMOS lifecycle events fire on transitions only and
    // never replay current state — if the platform's first
    // onApplicationForeground / onAbilityForeground transition lands while
    // init is still doing its async work (storage + device-id + module
    // inits + SBS fetch), the observer must already be subscribed or we
    // permanently miss the cold-boot session and auto-view. The observer's
    // own ready-gate (see `markReady` below) buffers any event that arrives
    // mid-init and replays it once the modules are loaded enough to handle
    // it; we do NOT synthesise events.
    this.lifecycleObserver.register(this.config.context);

    if (!this.config.context) {
      // No context means no preferences file — the SDK will run in memory
      // only and everything will reset on process restart. Surface this at
      // ERROR so the integrator can see it in both console and log listeners.
      this.config.logger.e('[Countly] init, no context provided — persistence is disabled, device id will regenerate on restart');
    } else if (this.config.storage) {
      const ok: boolean = await this.config.storage.init(this.config.context);
      if (!ok) {
        this.config.logger.e('[Countly] init, storage init failed — persistence is disabled, device id will regenerate on restart');
      }
    }
    // Apply persisted / dev-supplied SDK Behavior Settings BEFORE the request
    // queue loads — `requestDropAgeHours`, `maxRequestQueueSize`, and the
    // `dort` killswitch are all checked inside `RequestQueue.load`/`tick`.
    // Doing this here (instead of in `onInit`) keeps the apply ordering aligned
    // with the dev guide §SDK Behavior Settings precedence table.
    await this.configurationModule.loadFromStorage();
    await this.requestQueue.load();
    if (this.config.startInOfflineMode) {
      // Pause the processor so queued requests stay local until the integrator
      // calls `disableOfflineMode(...)`. Load persisted requests first so they
      // survive the pause.
      this.requestQueue.pause();
      this.config.logger.i('[Countly] init, starting in offline mode — no network traffic until disableOfflineMode()');
    }
    await this.deviceIdModule.resolveInitial();

    // Send the init-time consent snapshot NOW — bypassing the 1-second
    // coalesce timer the ModuleConsent constructor scheduled — so the consent
    // change lands in the request queue ahead of any begin_session that fires
    // when the platform delivers the cold-boot onApplicationForeground.
    // Sequencing: persisted requests (loaded by `requestQueue.load`) ship
    // first, then this consent snapshot, then everything else the module
    // inits enqueue. The coalesce timer remains correct for runtime consent
    // dialog toggles, so this method only flushes if a snapshot is pending.
    await this.consentModule.flushInitialConsentIfPending();

    // Never log the full device ID — it's a stable identifier that could
    // leak via a log listener. Log only the type.
    this.config.logger.i(`[Countly] init complete appKey=${this.config.appKey} deviceIdType=${this.deviceIdModule.getType()}`);
    await this.eventsModule.onInit();
    await this.viewsModule.onInit();
    await this.sessionsModule.onInit();
    await this.crashesModule.onInit();
    // userProfile.onInit applies any initial properties supplied via
    // CountlyConfig#userProfile.setProperties; without this hook the
    // pre-init properties never reach `setProperties` and the first
    // save()/event-triggered flush has nothing to send.
    await this.userProfileModule.onInit();
    await this.locationModule.onInit();
    await this.remoteConfigModule.onInit();
    await this.pushModule.onInit();
    await this.contentModule.onInit();
    await this.feedbackModule.onInit();
    // SBS server fetch fires here so it can observe device-id resolution
    // (skips on temp mode) and the per-module init logs/requests. Awaited so
    // the next test-tick sees the timer armed and the request recorded.
    await this.configurationModule.onInit();
    // Health check LAST so it can observe any error/warning logs + failed
    // requests from the earlier module inits before deciding what to ship.
    await this.healthCheckModule.onInit();
    // Flush any platform fg/auto-view event the observer captured while we
    // were still loading. The observer was registered at the top of init();
    // any transition that happened during the async pipeline is buffered
    // there. `markReady()` replays it now that storage, device-id, the
    // request queue, and every module's `onInit` have completed — so a
    // begin_session enqueue here goes through the fully-loaded pipeline.
    this.lifecycleObserver.markReady();
  }

  // -- SdkCore interface --
  // Device-id + consent reads are not exposed here — they live on the
  // `deviceId` and `consent` facades. Internal modules read them via
  // `core.consentModule.hasConsent(...)` / `core.deviceIdModule.*` (see
  // SdkCore.ets).

  public async saveUserProfileIfPending(): Promise<void> {
    if (this.userProfileModule.hasPendingChanges()) {
      await this.userProfileModule.save();
    }
  }

  public async flushEvents(): Promise<void> {
    await this.eventsModule.flushEventQueue();
  }

  public hasPendingEvents(): boolean {
    return this.eventsModule.hasPendingEvents();
  }

  public async notifyConsentWillChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    // Each hook is pre-wrapped in captureRejection so Promise.all behaves like
    // allSettled here — one module's failure is logged and swallowed, never
    // aborting peers. Every feature module is notified so they can flush
    // in-flight work before the consent flip.
    const promises: Promise<void>[] = this.consentRecipients.map((lm: LabeledModule): Promise<void> =>
      this.captureRejection(`${lm.label}.consentWillChange`, lm.module.consentWillChange(added, removed, source))
    );
    await Promise.all(promises);
  }

  public async notifyConsentDidChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    const promises: Promise<void>[] = this.consentRecipients.map((lm: LabeledModule): Promise<void> =>
      this.captureRejection(`${lm.label}.onConsentChanged`, lm.module.onConsentChanged(added, removed, source))
    );
    await Promise.all(promises);
  }

  /**
   * Wraps a module promise so a rejection is logged with the module/hook
   * name and then resolved. Lets Promise.all act as "allSettled" for us
   * without the SDK depending on Promise.allSettled availability.
   */
  private captureRejection(tag: string, p: Promise<void>): Promise<void> {
    return p.catch((err: Object) => {
      this.config.logger.e(`[Countly] ${tag} rejected: ${err}`);
    });
  }

  // -- Lifecycle --

  public lifecycleForeground(): void {
    this.sessionsModule.onEnterForeground();
    this.eventsModule.onEnterForeground();
    this.viewsModule.onEnterForeground();
    // Note: the post-foreground orientation baseline is now driven by
    // `ModuleSessions.beginSessionInternal` via the orientation-baseline
    // emitter wired in the constructor (Android parity, sdk/ModuleSessions.java:67-68).
    // That insertion point fires only when a session actually begins,
    // matching Android's gating exactly. The display read for rotations
    // that happened while backgrounded still happens — it just lives
    // inside that emitter path now.
  }

  public lifecycleBackground(): void {
    this.sessionsModule.onEnterBackground();
    this.eventsModule.onEnterBackground();
    this.viewsModule.onEnterBackground();
  }

  /**
   * Wired into `LifecycleObserver`'s `environment.onConfigurationUpdated`
   * when `trackOrientationChanges` is on. Mirrors Android's per-Activity
   * orientation check (sdk/ModuleViews.java:585), but driven by the system
   * config update instead of a per-Activity hook — HMOS's config-update
   * channel is the platform-correct trigger for rotation events.
   *
   * `Configuration.direction` is the canonical orientation field:
   *   DIRECTION_VERTICAL (0)   → portrait
   *   DIRECTION_HORIZONTAL (1) → landscape
   *   DIRECTION_NOT_SET (-1)   → ignored (no-op)
   *
   * The dedup against `lastOrientationMode` lives inside
   * `ModuleViews.updateOrientation`, so unrelated config changes (locale,
   * theme) that don't affect orientation cost essentially nothing.
   */
  private handleConfigurationUpdated(config: SystemConfig): void {
    const dir: number | undefined = config.direction;
    if (dir === undefined) return;
    let mode: string = '';
    if (dir === ConfigurationConstant.Direction.DIRECTION_VERTICAL) mode = 'portrait';
    else if (dir === ConfigurationConstant.Direction.DIRECTION_HORIZONTAL) mode = 'landscape';
    else return; // DIRECTION_NOT_SET — nothing to report
    this.viewsModule.updateOrientation(mode).catch((err: Object): void => {
      this.config.logger.e(`[Countly] auto-orientation updateOrientation rejected: ${err}`);
    });
  }

  /**
   * Read orientation from the display directly. Wired into
   * `ModuleSessions.beginSessionInternal` via `setOrientationBaselineEmitter`
   * so a fresh baseline orientation event is emitted on every session
   * begin — including session begins that follow a backgrounded rotation
   * which `onConfigurationUpdated` never delivered (that callback only
   * fires while the app is foregrounded).
   *
   * `forceSend=true` at this insertion point bypasses
   * `ModuleViews.updateOrientation`'s dedupe so each session begin sees
   * its own orientation event, matching Android's behavior at
   * sdk/ModuleSessions.java:67-68.
   */
  private maybeUpdateOrientationFromDisplay(forceSend: boolean): void {
    let mode: string = '';
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      mode = d.height >= d.width ? 'portrait' : 'landscape';
    } catch (err) {
      this.config.logger.d(`[Countly] auto-orientation, display unavailable: ${err}`);
      return;
    }
    this.viewsModule.updateOrientation(mode, forceSend).catch((err: Object): void => {
      this.config.logger.e(`[Countly] auto-orientation (display) updateOrientation rejected: ${err}`);
    });
  }

  /**
   * Wired into `LifecycleObserver`'s `abilityLifecycle.onAbilityForeground`
   * when `enableAutomaticViewTracking()` is set. Mirrors Android's
   * `ModuleViews.onActivityStarted` (sdk/ModuleViews.java:564):
   *
   *   1. Pick the long form (`bundle.Ability`) by default to match Android's
   *      `getName()`; switch to the short form (`Ability`) when
   *      `enableAutomaticViewShortNames()` is on, matching `getSimpleName()`.
   *   2. Skip ability names listed via `setAutomaticViewTrackingExclusions`.
   *   3. Hand the chosen name + global segmentation to
   *      `viewsModule.startAutoStoppedView` — same entrypoint manual code
   *      uses, so all the per-view rules (auto-stop the previous one,
   *      apply view-id, dispatch through the events pipeline) come for
   *      free without duplicating ModuleViews logic here.
   *
   * Errors thrown by the views module are logged (not rethrown) so the
   * platform's lifecycle dispatch isn't poisoned by a single SDK fault.
   */
  private handleAutoTrackedAbilityForeground(shortName: string, fullName: string): void {
    const name: string = this.config.automaticViewShortNames ? shortName : fullName;
    if (name.length === 0) {
      this.config.logger.d('[Countly] auto-view, empty ability name — skipped');
      return;
    }
    if (this.config.autoViewExclusions.indexOf(name) !== -1) {
      this.config.logger.d(`[Countly] auto-view, excluded: ${name}`);
      return;
    }
    this.viewsModule.startAutoStoppedView(name, this.config.globalViewSegmentation)
      .catch((err: Object): void => {
        this.config.logger.e(`[Countly] auto-view startAutoStoppedView rejected: ${err}`);
      });
  }

  public async halt(): Promise<void> {
    // Drop our applicationStateChange subscription FIRST so a fg/bg event
    // mid-shutdown doesn't try to drive modules whose onHalt is already
    // running. After this call, lifecycle is integrator-driven only.
    try { this.lifecycleObserver.deregister(); }
    catch (e) { this.config.logger.e(`[Countly] halt, lifecycleObserver deregister rejected: ${e}`); }
    // Await in order so pending events land first, then session end, then
    // final crash flush. Any rejection is caught so shutdown still proceeds.
    try { await this.eventsModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, events onHalt rejected: ${e}`); }
    try { await this.sessionsModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, sessions onHalt rejected: ${e}`); }
    try { await this.crashesModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, crashes onHalt rejected: ${e}`); }
    try { await this.contentModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, content onHalt rejected: ${e}`); }
    try { await this.feedbackModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, feedback onHalt rejected: ${e}`); }
    // AppStorage is process-wide; modules' onHalt already hides their
    // overlays, but call clearAll as a belt-and-braces measure so
    // re-initialising the SDK in tests (haltAll + initShared again) starts
    // with known-empty overlay state.
    try { OverlayStore.clearAll(); }
    catch (e) { this.config.logger.e(`[Countly] halt, OverlayStore clear rejected: ${e}`); }
    // Revert any IMMERSIVE window-layout change so a re-init (or the app
    // continuing after haltAll in a test) doesn't inherit a fullscreen
    // window that the next overlay didn't actually ask for.
    try { WindowImmersive.reset(this.config.context, this.config.logger); }
    catch (e) { this.config.logger.e(`[Countly] halt, WindowImmersive reset rejected: ${e}`); }
    // Health check onHalt persists counters so lifecycle-end doesn't lose them.
    try { await this.healthCheckModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, healthCheck onHalt rejected: ${e}`); }
    // Stop the SBS periodic-fetch timer; otherwise a detached instance keeps
    // firing fetches against a network that may be reset between tests.
    try { await this.configurationModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] halt, configuration onHalt rejected: ${e}`); }

    // Cancel any pending background timers so a detached instance's callbacks
    // don't fire on the next test / integration. This matters more than it
    // sounds: in a test harness `haltAll()` is called between tests, and a
    // lingering coalesce or backoff timer can cause the next test's fakes to
    // see cross-contamination.
    this.consentModule.cancelPendingTimers();
    this.requestQueue.halt();
  }

  // -- Instance-level (cross-module / integration-wide) operations --

  /**
   * Supply a URL opener so the SDK can open external links (from
   * `action=link` / `cly_x_int=1`) in the system browser. Usually wired
   * from the integrator's ability because opening a URL needs a
   * UIAbilityContext; passing null unbinds so links are blocked and logged.
   * Applies to BOTH content and feedback overlays — that's why this lives at
   * the instance level rather than on either sub-namespace.
   */
  public setExternalUrlOpener(opener: ((url: string) => void) | null): void {
    this.config.logger.i(`[Countly] Calling setExternalUrlOpener, opener=[${opener !== null}]`);
    this.contentModule.setExternalUrlOpener(opener);
    this.feedbackModule.setExternalUrlOpener(opener);
  }

  // -- Overlay callbacks (invoked by CountlyContentOverlay / CountlyFeedbackOverlay) --
  // All overlay handlers are no-op'd while the content + feedback modules are
  // disabled. Returning `false` from the URL handlers tells the WebView to
  // continue with default navigation; in practice the overlay components
  // never render because their backing state is never published, but we
  // defend against a stale CountlyOverlayRoot mount by short-circuiting here.

  /** @internal — called by the exported overlay component on WebView load intercept. */
  public handleContentOverlayUrl(url: string): boolean {
    this.config.logger.w('[Countly] handleContentOverlayUrl — content module is disabled, no-op');
    return false;
  }
  /** @internal — called by the exported overlay component when dismissed. */
  public onContentOverlayClosed(status: ContentStatus, data: Record<string, Object>): void {
    this.config.logger.w('[Countly] onContentOverlayClosed — content module is disabled, no-op');
  }
  /** @internal — called by the exported overlay component on WebView load timeout. */
  public onContentOverlayLoadTimedOut(): void {
    this.config.logger.w('[Countly] onContentOverlayLoadTimedOut — content module is disabled, no-op');
  }
  /** @internal — called by the exported feedback overlay on WebView load intercept. */
  public handleFeedbackOverlayUrl(url: string): boolean {
    this.config.logger.w('[Countly] handleFeedbackOverlayUrl — feedback module is disabled, no-op');
    return false;
  }
  /** @internal — called by the exported feedback overlay when dismissed. */
  public onFeedbackOverlayClosed(): void {
    this.config.logger.w('[Countly] onFeedbackOverlayClosed — feedback module is disabled, no-op');
  }
  /** @internal — called by the exported feedback overlay on WebView load timeout. */
  public onFeedbackOverlayLoadTimedOut(): void {
    this.config.logger.w('[Countly] onFeedbackOverlayLoadTimedOut — feedback module is disabled, no-op');
  }

  // -- Other Features --

  /**
   * Change the server URL at runtime. Basic scheme + authority validation is
   * re-run (same policy as the CountlyConfig constructor); previously-queued
   * requests stay in place and will be sent to the new URL on the next tick.
   */
  public setServerURL(url: string): void {
    const reason: string = Utils.validateServerUrl(url);
    if (reason === 'empty') {
      this.config.logger.w('[Countly] setServerURL, empty url — ignored');
      return;
    }
    if (reason === 'scheme') {
      this.config.logger.w(`[Countly] setServerURL, must start with http:// or https:// — ignored (${url})`);
      return;
    }
    if (reason === 'authority') {
      this.config.logger.e('[Countly] setServerURL, authority contains "@" — ignored (userinfo hazard)');
      return;
    }
    this.config.serverUrl = Utils.stripTrailingSlashes(url);
    this.config.logger.i('[Countly] setServerURL, server URL updated — queued requests will send to the new host');
  }

}
