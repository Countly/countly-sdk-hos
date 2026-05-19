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
 * which event, `userProfile` is a deliberate consent recipient but not a
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

  /** @internal, module-to-module reads only (see SdkCore). User-facing reads
   * live on `consent` / `deviceId` facades; this field exists solely so
   * other modules can call `core.consentModule.hasConsent(...)`. */
  public readonly consentModule: ModuleConsent;
  /** @internal, see consentModule note. */
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
   * instance owns its own, multiple instances each get their own
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
  // Push, content, and feedback are intentionally `private`, these modules
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
    this.config.initialConsentAll = countlyConfig.consent.initialAll;
    this.config.unknownConsentMode = countlyConfig.consent.unknownMode;
    // Unknown consent mode internally grants every feature so module-level
    // `hasConsent` gates open and telemetry actually reaches the request
    // queue. The queue itself is paused in `init()` so the buffered data
    // sits locally until `giveConsentAll` / `removeConsentAll` resolves the
    // unknown state. `enableUnknownConsentMode()` already flips `requires=true`
    //, re-asserting here so a future caller setting `unknownConsentMode`
    // directly on InternalConfig (tests) can't bypass that invariant.
    if (this.config.unknownConsentMode) {
      this.config.requiresConsent = true;
      this.config.initialConsentAll = true;
    }

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
    // Seed the automatic-tracking trio (avt/ast/acr) on ServerConfig FROM the
    // integrator-supplied flags BEFORE any SBS layer applies. Precedence is
    // server > storage > integrator, and SBS only overwrites keys that are
    // actually present in the payload — so seeding here gives the integrator
    // setting authority whenever the SBS layers are silent for that key.
    // `automaticSessionTrackingEnabled` is the inverse of `manualSessionControl`:
    // opting into manual control implies opting out of automatic.
    this.config.serverConfig.automaticSessionTrackingEnabled = !this.config.manualSessionControl;
    this.config.serverConfig.automaticCrashReportingEnabled = this.config.enableCrashReporting;
    this.config.serverConfig.automaticViewTrackingEnabled = this.config.automaticViewTracking;
    this.configurationModule.applyDevSuppliedSettings();
    this.consentModule = new ModuleConsent(this.config, this);

    this.eventsModule = new ModuleEvents(this.config, this);
    if (this.config.experimentalVisibilityTracking) this.eventsModule.enableVisibilityTracking();
    if (this.config.experimentalPreviousNameRecording) this.eventsModule.enablePreviousNameRecording();
    this.viewsModule = new ModuleViews(this.config, this, this.eventsModule);
    this.eventsModule.setViewIdProvider((): ViewIds => this.viewsModule.getIds());

    this.sessionsModule = new ModuleSessions(this.config, this);
    this.sessionsModule.setFirstViewFlagHost(this.viewsModule.getFirstViewFlagHost());
    // Orientation baseline at session begin. Gated on `trackOrientationChanges`
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
    // deliberately does NOT auto-flush, dev guide §1482 says legacy star
    // rating recordings from other paths must not trigger an immediate flush.
    // The explicit flush below covers only the feedback Rating widget path
    // without affecting those legacy recordings. A future change that adds
    // `[CLY]_star_rating` to IMMEDIATE_FLUSH_KEYS would double-flush here,
    // harmless but a sign to delete this branch.
    this.feedbackModule.setFeedbackEventRecorder(async (key: string, seg: SegmentationMap): Promise<void> => {
      await this.eventsModule.recordEvent(key, seg, 1, 0, 0);
      if (key === '[CLY]_star_rating') {
        await this.eventsModule.flushEventQueue();
      }
    });

    // Content-emitted events ride the same pipeline so consent is respected
    // and the events join any in-flight batch. The queue flush afterwards
    // surfaces content actions quickly, they are short-lived interactions
    // that integrators expect to land promptly.
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
    // Auto-view tracking is always wired so a runtime SBS flip to `avt=true`
    // can activate it even when the integrator didn't call
    // `enableAutomaticViewTracking()`. The actual decision lives inside
    // `handleAutoTrackedAbilityForeground`, which reads
    // `serverConfig.automaticViewTrackingEnabled` (seeded from the integrator
    // flag, then overlaid by storage / server SBS layers).
    // Auto-orientation tracking stays gated on `trackOrientationChanges` only —
    // it's not part of the avt/ast/acr trio.
    const autoViewCallback: ((shortName: string, fullName: string) => void) | null =
      (shortName: string, fullName: string): void => this.handleAutoTrackedAbilityForeground(shortName, fullName);
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
    // keeps state, modules are notified separately so they can do bookkeeping.
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

    // Pre-swap hook for changeWithoutMerge: emit end_session (non-manual + active
    // session only) and reset consent UNDER THE OLD ID, before the device-id
    // commit. Manual mode skips end_session entirely (the integrator owns
    // session lifecycle).
    this.deviceIdModule.setBeforeNonMergedSwapHook(async (_oldId: string, _newId: string): Promise<void> => {
      if (!this.config.manualSessionControl && this.sessionsModule.isSessionActive()) {
        await this.sessionsModule.endSessionForDeviceIdChange();
      }
      await this.consentModule.resetForDeviceIdChangeNotMerged();
    });

    this.deviceIdModule.setChangeListener(async (oldId: string, newId: string, merged: boolean): Promise<void> => {
      if (merged) {
        const promises: Promise<void>[] = this.deviceIdMergedRecipients.map((lm: LabeledModule): Promise<void> =>
          this.captureRejection(`${lm.label}.onDeviceIdChangedMerged`, lm.module.onDeviceIdChangedMerged(oldId, newId))
        );
        await Promise.all(promises);
      } else {
        // Consent reset + session end already happened pre-swap; this fan-out
        // is purely for modules that need to react to the new identity (cache
        // invalidation, RC re-download, lifecycle counter resets, etc.).
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
      this.config.logger.e('[Countly] init, already initialized, ignoring (check for duplicate init() calls)');
      return;
    }
    this.initialized = true;

    // Register the lifecycle observer SYNCHRONOUSLY before any await below
    // yields control. HMOS lifecycle events fire on transitions only and
    // never replay current state, if the platform's first
    // onApplicationForeground / onAbilityForeground transition lands while
    // init is still doing its async work (storage + device-id + module
    // inits + SBS fetch), the observer must already be subscribed or we
    // permanently miss the cold-boot session and auto-view. The observer's
    // own ready-gate (see `markReady` below) buffers any event that arrives
    // mid-init and replays it once the modules are loaded enough to handle
    // it; we do NOT synthesise events.
    this.lifecycleObserver.register(this.config.context);

    if (!this.config.context) {
      // No context means no preferences file, the SDK will run in memory
      // only and everything will reset on process restart. Surface this at
      // ERROR so the integrator can see it in both console and log listeners.
      this.config.logger.e('[Countly] init, no context provided, persistence is disabled, device id will regenerate on restart');
    } else if (this.config.storage) {
      const ok: boolean = await this.config.storage.init(this.config.context);
      if (!ok) {
        this.config.logger.e('[Countly] init, storage init failed, persistence is disabled, device id will regenerate on restart');
      }
    }
    // Apply persisted / dev-supplied SDK Behavior Settings BEFORE the request
    // queue loads, `requestDropAgeHours`, `maxRequestQueueSize`, and the
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
      this.config.logger.i('[Countly] init, starting in offline mode, no network traffic until disableOfflineMode()');
    }
    if (this.config.unknownConsentMode) {
      // Same pause primitive as offline mode, collected telemetry queues
      // locally until `giveConsentAll` / `removeConsentAll` resolves the
      // unknown state. The instance keeps running through resolution; the
      // queue is resumed (and the Network unsilenced) by `resolveUnknownConsent`.
      // Loaded queue contents from a previous unknown-mode session also stay
      // paused so a re-launch into unknown mode preserves "nothing leaves the
      // device".
      this.requestQueue.pause();
      // Belt and braces: silence the Network too so any direct-execute
      // telemetry path that bypasses the queue (RC auto-download, A/B
      // enrollment) is blocked at the transport. SBS fetch and Health
      // Check intentionally bypass the silencer via
      // `Network.executeOperational()` because they carry no
      // event/session/view/profile data and are critical for SDK
      // correctness (server-driven config + reliability counters)
      // regardless of consent state. `resolveUnknownConsent` calls
      // `setSilenced(false)` on either resolution path so even the
      // telemetry-bearing paths re-open for buffered drain (give) or
      // the revocation snapshot (revoke).
      this.config.network.setSilenced(true);
      this.config.logger.i('[Countly] init, starting in unknown consent mode, telemetry held locally until giveConsentAll/removeConsentAll');
    }
    await this.deviceIdModule.resolveInitial();

    // Send the init-time consent snapshot NOW, bypassing the 1-second
    // coalesce timer the ModuleConsent constructor scheduled, so the consent
    // change lands in the request queue ahead of any begin_session that fires
    // when the platform delivers the cold-boot onApplicationForeground.
    // Sequencing: persisted requests (loaded by `requestQueue.load`) ship
    // first, then this consent snapshot, then everything else the module
    // inits enqueue. The coalesce timer remains correct for runtime consent
    // dialog toggles, so this method only flushes if a snapshot is pending.
    await this.consentModule.flushInitialConsentIfPending();

    // Never log the full device ID, it's a stable identifier that could
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
    // Reconcile auto-crash install: ModuleCrashes.onInit ran BEFORE the server
    // fetch landed, so a first-run server response that flipped `acr` (either
    // direction — integrator-enabled but server says false, or integrator-
    // silent but server says true) needs a second pass to install / uninstall
    // the platform error observer accordingly. `reconcileAutoInstall` handles
    // both directions and is a no-op when nothing changed.
    this.crashesModule.reconcileAutoInstall();
    // Health check LAST so it can observe any error/warning logs + failed
    // requests from the earlier module inits before deciding what to ship.
    await this.healthCheckModule.onInit();
    // Flush any platform fg/auto-view event the observer captured while we
    // were still loading. The observer was registered at the top of init();
    // any transition that happened during the async pipeline is buffered
    // there. `markReady()` replays it now that storage, device-id, the
    // request queue, and every module's `onInit` have completed, so a
    // begin_session enqueue here goes through the fully-loaded pipeline.
    this.lifecycleObserver.markReady();
  }

  // -- SdkCore interface --
  // Device-id + consent reads are not exposed here, they live on the
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

  /**
   * Test seam — surfaces whether the HarmonyOS `errorManager` observer is
   * currently registered. Lets acr precedence tests verify the actual install
   * decision instead of just the underlying flag.
   */
  public isAutomaticCrashHandlerInstalled(): boolean {
    return this.crashesModule.isErrorHandlerInstalled();
  }

  public async notifyConsentWillChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    // Each hook is pre-wrapped in captureRejection so Promise.all behaves like
    // allSettled here, one module's failure is logged and swallowed, never
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
    // Post-halt fan-out gate. Module-level mutators already check
    // `rejectIfHalted`, but the lifecycle hooks (`onEnterForeground`,
    // `onEnterBackground`) call through to internal helpers
    // (`recordViewEvent` → private `recordEventAt`) that bypass those gates.
    // The LifecycleObserver is deregistered on halt, so this only matters
    // for manual `lifecycleForegroundAll` calls, but those WOULD have
    // re-queued telemetry on a halted instance without this guard.
    if (this.config.halted) {
      this.config.logger.w('[Countly] lifecycleForeground called after halt, ignored');
      return;
    }
    this.sessionsModule.onEnterForeground();
    this.eventsModule.onEnterForeground();
    this.viewsModule.onEnterForeground();
    // Note: the post-foreground orientation baseline is now driven by
    // `ModuleSessions.beginSessionInternal` via the orientation-baseline
    // emitter wired in the constructor. That insertion point fires only
    // when a session actually begins. The display read for rotations
    // that happened while backgrounded still happens, it just lives
    // inside that emitter path now.
  }

  public lifecycleBackground(): void {
    if (this.config.halted) {
      this.config.logger.w('[Countly] lifecycleBackground called after halt, ignored');
      return;
    }
    this.sessionsModule.onEnterBackground();
    this.eventsModule.onEnterBackground();
    this.viewsModule.onEnterBackground();
  }

  /**
   * Wired into `LifecycleObserver`'s `environment.onConfigurationUpdated`
   * when `trackOrientationChanges` is on. HMOS's config-update channel is
   * the platform-correct trigger for rotation events.
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
    else return; // DIRECTION_NOT_SET, nothing to report
    this.viewsModule.updateOrientation(mode).catch((err: Object): void => {
      this.config.logger.e(`[Countly] auto-orientation updateOrientation rejected: ${err}`);
    });
  }

  /**
   * Read orientation from the display directly. Wired into
   * `ModuleSessions.beginSessionInternal` via `setOrientationBaselineEmitter`
   * so a fresh baseline orientation event is emitted on every session
   * begin, including session begins that follow a backgrounded rotation
   * which `onConfigurationUpdated` never delivered (that callback only
   * fires while the app is foregrounded).
   *
   * `forceSend=true` at this insertion point bypasses
   * `ModuleViews.updateOrientation`'s dedupe so each session begin sees
   * its own orientation event.
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
   * when `enableAutomaticViewTracking()` is set:
   *
   *   1. Pick the long form (`bundle.Ability`) by default; switch to the
   *      short form (`Ability`) when `enableAutomaticViewShortNames()` is on.
   *   2. Skip ability names listed via `setAutomaticViewTrackingExclusions`.
   *   3. Hand the chosen name + global segmentation to
   *      `viewsModule.startAutoStoppedView`, same entrypoint manual code
   *      uses, so all the per-view rules (auto-stop the previous one,
   *      apply view-id, dispatch through the events pipeline) come for
   *      free without duplicating ModuleViews logic here.
   *
   * Errors thrown by the views module are logged (not rethrown) so the
   * platform's lifecycle dispatch isn't poisoned by a single SDK fault.
   */
  private handleAutoTrackedAbilityForeground(shortName: string, fullName: string): void {
    // Single gate: `automaticViewTrackingEnabled` is seeded from the
    // integrator's `enableAutomaticViewTracking()` opt-in, then overlaid by
    // storage / server SBS layers (server > storage > integrator). Reading it
    // here encodes the full precedence — either side enabling is enough.
    if (!this.config.serverConfig.automaticViewTrackingEnabled) {
      return;
    }
    const name: string = this.config.automaticViewShortNames ? shortName : fullName;
    if (name.length === 0) {
      this.config.logger.d('[Countly] auto-view, empty ability name, skipped');
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

  /**
   * @internal, invoked by `ModuleConsent` when the integrator calls
   * `consent.giveConsentAll()` / `removeConsentAll()` while unknown mode is
   * active. Not intended to be called directly by integrators; the only
   * supported way to leave unknown mode is via the consent facade. When the
   * instance isn't in unknown mode the call is a no-op (warning logged).
   *
   * Resolution semantics (both paths KEEP the instance running, there is
   * no halt; the integrator does not need to re-init):
   *
   * - `givenAll=true`, "consent given, network calls can start." Unsilences
   *   the transport and resumes the request queue. The data buffered during
   *   the unknown phase (events, session begin, the init-time consent
   *   snapshot reflecting all-granted state) drains naturally to the wire.
   *   Analogous to exiting temporary device-id mode.
   *
   * - `givenAll=false`, "consent revoked, erase collected data, send
   *   revocation, keep running like consent not given." Wipes the buffered
   *   queue, flips every consent to false, ships a single all-false
   *   `consent=` snapshot, and locks the runtime consent surface
   *   (`consentLockedPostUnknown`) so subsequent `giveConsentAll` /
   *   `removeConsentAll` runtime calls are no-ops with a "consent is set
   *   per init" warning log. The integrator must re-init with a fresh
   *   `CountlyConfig` to escape the lock.
   */
  public async resolveUnknownConsent(givenAll: boolean): Promise<void> {
    if (!this.config.unknownConsentMode) {
      this.config.logger.w('[Countly] resolveUnknownConsent called outside unknown mode, ignored');
      return;
    }
    // Clear the flag FIRST so re-entry is impossible during the async work
    // below (a fast second `giveConsentAll`/`removeConsentAll` would find
    // `unknownConsentMode=false` and run the normal non-UCM path).
    this.config.unknownConsentMode = false;
    // Unsilence the transport regardless of resolution, either we're
    // about to ship the buffered queue (give) or a revocation snapshot
    // (revoke). The silencer is no longer needed.
    this.config.network.setSilenced(false);

    // Fire deferred operational requests (HC + SBS) BEFORE the grant/
    // revoke branch so they reach the wire on both paths. This matches
    // Dart's `_getOutOfUnknownConsentState`, both modules check their
    // own preconditions internally (HC sent flag, SBS disabled flag,
    // temp-id mode), the calls are fire-and-forget so they don't gate
    // the rest of resolution on network round-trips.
    this.configurationModule.triggerPostUcmRefresh();
    this.healthCheckModule.triggerPostUcmSend();

    if (givenAll) {
      this.config.logger.i('[Countly] resolveUnknownConsent, givenAll=true, network calls enabled, buffered data will ship');
      // Resume the queue; the init-time consent snapshot + any buffered
      // events/sessions/views drain in arrival order. Internal consent
      // map is already all-true (set by `initialConsentAll=true` at
      // construction), so the SDK simply continues operating with full
      // consent, no module-level state change needed.
      this.requestQueue.resume();
      return;
    }

    this.config.logger.i(`[Countly] removeConsentAll, unknown consent mode: erasing buffered data and sending revocation at ${Date.now()} (${new Date().toISOString()})`);
    // Flip every consent to false. notifyConsentDidChange fires; modules
    // may enqueue cleanup requests (end_session, location erasure, etc.)
    // into the still-paused queue. Those are about to be dropped.
    this.config.logger.i('[Countly] removeConsentAll, flipping all consents to false and notifying modules');
    await this.consentModule.applyRevokeFromUnknownMode_phase1();
    this.config.logger.i('[Countly] removeConsentAll, consent flip complete');
    // Drop everything: buffered-during-UCM data PLUS the cleanup requests
    // modules just emitted. The server never observed the implicit "all
    // granted" state, so it must not see the cleanup either. The
    // coalesced revocation snapshot timer scheduled above is NOT touched
    // by queue.clear(), it stays pending and is flushed explicitly next.
    this.config.logger.i('[Countly] removeConsentAll, clearing buffered request queue');
    await this.requestQueue.clear();
    this.config.logger.i('[Countly] removeConsentAll, buffered queue cleared');
    // Ship the revocation snapshot. This is the ONLY wire request the
    // server sees from this resolution.
    this.config.logger.i('[Countly] removeConsentAll, sending revocation snapshot (all features = false)');
    await this.consentModule.applyRevokeFromUnknownMode_phase2();
    this.config.logger.i('[Countly] removeConsentAll, revocation snapshot enqueued');
    // Lock the runtime consent surface. From this point on,
    // `giveConsentAll` / `removeConsentAll` log "consent is set per init"
    // and return without effect.
    this.config.consentLockedPostUnknown = true;
    // Resume so the queued revocation snapshot ships. Any subsequent
    // integrator-initiated wire activity (none should happen with consent
    // revoked, but addDirectRequest etc. would still be blocked by the
    // module-level consent gate) flows after.
    this.requestQueue.resume();
  }

  /**
   * Halt the instance WITHOUT wiping persisted storage. Drains module state
   * to the request queue, halts the queue, deregisters the lifecycle
   * observer, cancels background timers. The persisted request queue,
   * device ID, server-config cache, health-check counters, user-profile
   * cache, and remote-config cache all survive on disk, a subsequent
   * `Countly.initShared(cfg, sameStorage)` picks them up and resumes.
   *
   * Use `stop()` when you want to swap configurations at runtime (server-URL
   * change, etc.) without losing buffered telemetry. Use `halt()` when you
   * want a clean wipe (e.g., user-data deletion). `Countly.initShared`'s
   * smart auto-replace path uses `stop()` under the hood when replacing an
   * existing shared instance.
   *
   * Post-stop/halt gating contract (applies equally to `stop()`, `halt()`,
   * `Countly.stopAll()`, `Countly.haltAll()`):
   *   - `config.halted` is flipped to `true` BEFORE any module drain runs,
   *     so module-level mutators invoked from this point on (incl. during
   *     the drain itself, if an integrator races a call against shutdown)
   *     are rejected at the module's `rejectIfHalted` gate. The drains
   *     themselves call private module methods that bypass that gate.
   *   - Every user-facing module mutator (recordEvent, startView,
   *     beginSession, setProperty, setLocation, setID, addDirectRequest,
   *     give/removeConsentAll, …) becomes a no-op + warning log.
   *   - Gated instance-level methods (`lifecycleForeground`,
   *     `lifecycleBackground`, `setServerURL`, `setExternalUrlOpener`)
   *     are also no-op + warning log post-stop.
   *   - Read accessors (`getID`, `hasPendingEvents`, `checkAllConsent`,
   *     etc.) remain available.
   *   - Unknown Consent Mode resolution does NOT flip `halted`. The
   *     post-revoke "consent is set per init" lock
   *     (`config.consentLockedPostUnknown`) is a separate, narrower gate
   *     that only blocks runtime consent mutations.
   */
  public async stop(): Promise<void> {
    // Flip the global module gate FIRST so any user-facing module mutator
    // invoked from THIS point onward (including during halt drains, if an
    // integrator races a recordEvent against haltAll) is rejected at its
    // module's entry point. Internal halt-drain paths call private module
    // methods that intentionally bypass `rejectIfHalted`.
    this.config.halted = true;
    // Drop our applicationStateChange subscription FIRST so a fg/bg event
    // mid-shutdown doesn't try to drive modules whose onHalt is already
    // running. After this call, lifecycle is integrator-driven only.
    try { this.lifecycleObserver.deregister(); }
    catch (e) { this.config.logger.e(`[Countly] stop, lifecycleObserver deregister rejected: ${e}`); }
    // Await in order so pending events land first, then session end, then
    // final crash flush. Any rejection is caught so shutdown still proceeds.
    try { await this.eventsModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, events onHalt rejected: ${e}`); }
    try { await this.sessionsModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, sessions onHalt rejected: ${e}`); }
    try { await this.crashesModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, crashes onHalt rejected: ${e}`); }
    try { await this.contentModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, content onHalt rejected: ${e}`); }
    try { await this.feedbackModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, feedback onHalt rejected: ${e}`); }
    // AppStorage is process-wide; modules' onHalt already hides their
    // overlays, but call clearAll as a belt-and-braces measure so
    // re-initialising the SDK (a fresh `initShared` after stop) starts
    // with known-empty overlay state.
    try { OverlayStore.clearAll(); }
    catch (e) { this.config.logger.e(`[Countly] stop, OverlayStore clear rejected: ${e}`); }
    // Revert any IMMERSIVE window-layout change so a re-init doesn't inherit
    // a fullscreen window that the next overlay didn't actually ask for.
    try { WindowImmersive.reset(this.config.context, this.config.logger); }
    catch (e) { this.config.logger.e(`[Countly] stop, WindowImmersive reset rejected: ${e}`); }
    // Health check onHalt persists counters so lifecycle-end doesn't lose them.
    try { await this.healthCheckModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, healthCheck onHalt rejected: ${e}`); }
    // Stop the SBS periodic-fetch timer; otherwise a detached instance keeps
    // firing fetches against a network that may be reset between tests.
    try { await this.configurationModule.onHalt(); } catch (e) { this.config.logger.e(`[Countly] stop, configuration onHalt rejected: ${e}`); }

    // Cancel any pending background timers so a detached instance's callbacks
    // don't fire on the next test / integration. This matters more than it
    // sounds: in a test harness `stopAll()` / `haltAll()` is called between
    // tests, and a lingering coalesce or backoff timer can cause the next
    // test's fakes to see cross-contamination.
    this.consentModule.cancelPendingTimers();
    this.requestQueue.halt();
  }

  /**
   * Halt the instance AND wipe every persisted SDK key from storage,
   * device ID, request queue, server-config cache, health-check counters,
   * user-profile cache, remote-config cache, etc. This matches Android's
   * `Countly.halt()` behavior (which clears `countlyStore`).
   *
   * After `halt()`, a fresh `Countly.initShared(cfg)` starts from a clean
   * slate: a new device ID is generated, no buffered traffic, no stale
   * config. Use this for "user data deletion" flows.
   *
   * `stop()` runs first so module drains write their final state to disk
   * before the wipe, but since the entire backing preferences file is
   * cleared, the drained state is overwritten. The drain order doesn't
   * affect what the next init sees; the wipe is exhaustive.
   */
  public async halt(): Promise<void> {
    await this.stop();
    if (this.config.storage) {
      const ok: boolean = await this.config.storage.clear();
      if (!ok) {
        this.config.logger.w('[Countly] halt, storage.clear() returned false, persisted data may not be fully wiped');
      } else {
        this.config.logger.i('[Countly] halt, persisted storage wiped');
      }
    }
  }

  // -- Instance-level (cross-module / integration-wide) operations --

  /**
   * Supply a URL opener so the SDK can open external links (from
   * `action=link` / `cly_x_int=1`) in the system browser. Usually wired
   * from the integrator's ability because opening a URL needs a
   * UIAbilityContext; passing null unbinds so links are blocked and logged.
   * Applies to BOTH content and feedback overlays, that's why this lives at
   * the instance level rather than on either sub-namespace.
   */
  public setExternalUrlOpener(opener: ((url: string) => void) | null): void {
    if (this.config.halted) {
      this.config.logger.w('[Countly] setExternalUrlOpener called after halt, ignored');
      return;
    }
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

  /** @internal, called by the exported overlay component on WebView load intercept. */
  public handleContentOverlayUrl(url: string): boolean {
    this.config.logger.w('[Countly] handleContentOverlayUrl, content module is disabled, no-op');
    return false;
  }
  /** @internal, called by the exported overlay component when dismissed. */
  public onContentOverlayClosed(status: ContentStatus, data: Record<string, Object>): void {
    this.config.logger.w('[Countly] onContentOverlayClosed, content module is disabled, no-op');
  }
  /** @internal, called by the exported overlay component on WebView load timeout. */
  public onContentOverlayLoadTimedOut(): void {
    this.config.logger.w('[Countly] onContentOverlayLoadTimedOut, content module is disabled, no-op');
  }
  /** @internal, called by the exported feedback overlay on WebView load intercept. */
  public handleFeedbackOverlayUrl(url: string): boolean {
    this.config.logger.w('[Countly] handleFeedbackOverlayUrl, feedback module is disabled, no-op');
    return false;
  }
  /** @internal, called by the exported feedback overlay when dismissed. */
  public onFeedbackOverlayClosed(): void {
    this.config.logger.w('[Countly] onFeedbackOverlayClosed, feedback module is disabled, no-op');
  }
  /** @internal, called by the exported feedback overlay on WebView load timeout. */
  public onFeedbackOverlayLoadTimedOut(): void {
    this.config.logger.w('[Countly] onFeedbackOverlayLoadTimedOut, feedback module is disabled, no-op');
  }

  // -- Other Features --

  /**
   * Change the server URL at runtime. Basic scheme + authority validation is
   * re-run (same policy as the CountlyConfig constructor); previously-queued
   * requests stay in place and will be sent to the new URL on the next tick.
   */
  public setServerURL(url: string): void {
    if (this.config.halted) {
      this.config.logger.w('[Countly] setServerURL called after halt, ignored');
      return;
    }
    const reason: string = Utils.validateServerUrl(url);
    if (reason === 'empty') {
      this.config.logger.w('[Countly] setServerURL, empty url, ignored');
      return;
    }
    if (reason === 'scheme') {
      this.config.logger.w(`[Countly] setServerURL, must start with http:// or https://, ignored (${url})`);
      return;
    }
    if (reason === 'authority') {
      this.config.logger.e('[Countly] setServerURL, authority contains "@", ignored (userinfo hazard)');
      return;
    }
    this.config.serverUrl = Utils.stripTrailingSlashes(url);
    this.config.logger.i('[Countly] setServerURL, server URL updated, queued requests will send to the new host');
  }

}
