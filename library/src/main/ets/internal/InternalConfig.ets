import common from '@ohos.app.ability.common';
import { Logger } from './Logger';
import { Limits } from './Limits';
import { Network } from './Network';
import { Storage } from './Storage';
import { ServerConfig } from './ServerConfig';
import {
  GlobalCrashFilterCallback,
  ContentCallback,
  SegmentationMap,
  MessagingProvider,
  PushTestMode,
  PushActionHandler,
  RCDownloadCallback,
  WebViewDisplayOption
} from '../types/Types';

/**
 * Internal, derived, runtime configuration. Each Countly instance owns one of
 * these; modules read from it but should not mutate unrelated fields.
 */
export class InternalConfig {
  public serverUrl: string = '';
  public appKey: string = '';
  public sdkName: string = 'arkts-native-harmonyos';
  public sdkVersion: string = '26.1.0';
  public appVersion: string = '1.0';

  public context: common.Context | null = null;
  public logger: Logger = new Logger();
  public limits: Limits = new Limits();
  public network: Network;
  public storage: Storage | null = null;

  public customDeviceId: string | null = null;
  public clearStoredDeviceId: boolean = false;
  public startInTemporaryIdMode: boolean = false;

  public requiresConsent: boolean = false;
  public initialConsentAll: boolean = false;
  /**
   * Unknown consent mode (see ConsentConfig.enableUnknownConsentMode). When
   * true at init, the request queue is paused and consents are internally
   * granted so modules buffer telemetry locally. Cleared by
   * `CountlyInstance.resolveUnknownConsent` so subsequent re-inits aren't
   * trapped in unknown mode.
   */
  public unknownConsentMode: boolean = false;
  /**
   * Set after `removeConsentAll` resolves unknown consent mode. Locks the
   * runtime consent surface, `ModuleConsent.giveConsentAll` /
   * `removeConsentAll` log "consent is set per init" and no-op while this is
   * true. The lock is process-only; re-init with a fresh `CountlyConfig`
   * starts a new instance with `consentLockedPostUnknown=false`.
   *
   * Rationale: post-UCM-revoke the integrator's stance is "the user said
   * no", letting a later `giveConsentAll` flip that runtime would defeat
   * the revocation. The only way to re-enable consent is a new init.
   */
  public consentLockedPostUnknown: boolean = false;
  /**
   * Set to true by `CountlyInstance.stop()` / `halt()` BEFORE any module
   * drain runs. Every user-facing module mutator checks
   * `ModuleBase.rejectIfHalted(...)` which reads this flag; calls after
   * stop/halt are rejected with a warning log so post-shutdown state doesn't
   * silently leak (the original leak was reported as `recordEvent` calls
   * continuing to grow the in-memory event queue after the integrator
   * thought the instance had been shut down). Internal halt drains call
   * module *internal* methods (e.g. `flushEventQueue`) which do NOT check
   * this flag, so the drain itself still works. UCM resolution does NOT
   * flip this flag, `resolveUnknownConsent` keeps the instance running on
   * both the give and revoke paths.
   */
  public halted: boolean = false;

  public eventQueueThreshold: number = 100;
  public maxRequestQueueSize: number = 1000;
  public sessionUpdateIntervalSec: number = 60;
  // 7 days by default, prevents the queue from holding ancient requests on
  // permanent server outages (battery/data drain). Integrators can set 0 to
  // disable drop-by-age entirely.
  public requestDropAgeHours: number = 168;

  public manualSessionControl: boolean = false;
  public manualSessionHybridMode: boolean = false;

  public automaticViewTracking: boolean = false;
  public automaticViewShortNames: boolean = false;
  public autoViewExclusions: string[] = [];
  public globalViewSegmentation: SegmentationMap = {};
  public trackOrientationChanges: boolean = true;
  public disableViewRestartForManual: boolean = false;

  public enableCrashReporting: boolean = false;
  public recordAllThreadsWithCrash: boolean = false;
  public customCrashSegmentation: SegmentationMap = {};
  public crashFilter: GlobalCrashFilterCallback | null = null;

  public contentCallback: ContentCallback | null = null;
  public contentZoneInterval: number = 30;
  public contentCategories: string[] = [];
  public refreshContentZoneEnabled: boolean = true;
  public contentDisplayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;
  public contentAllowedOrigins: string[] = [];

  public feedbackDisplayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;

  public initialLocationCountry: string | null = null;
  public initialLocationCity: string | null = null;
  public initialLocationGps: string | null = null;
  public initialLocationIp: string | null = null;
  public locationDisabled: boolean = false;

  public metricOverride: Record<string, string> = {};
  public initialUserProperties: SegmentationMap = {};

  public parameterTamperingSalt: string | null = null;
  public backoffEnabled: boolean = true;

  public pushProvider: MessagingProvider = MessagingProvider.HMS;
  public pushTestMode: PushTestMode = PushTestMode.PRODUCTION;
  public pushSendTokenAlways: boolean = false;
  public pushActionHandler: PushActionHandler | null = null;
  public pushAllowedIntentTargets: string[] = [];

  /** Auto-enroll users in A/B testing on RC download (`oi=1` vs `oi=0`). */
  public remoteConfigABAutoOptin: boolean = false;
  public remoteConfigAutomaticTriggers: boolean = false;
  public remoteConfigValueCaching: boolean = false;
  public remoteConfigGlobalCallback: RCDownloadCallback | null = null;

  public startInOfflineMode: boolean = false;
  public disableHealthCheck: boolean = false;

  /**
   * Server-pushed runtime config (filters, feature flags, queue size limits).
   * `ModuleConfiguration` populates this from storage + `/o/sdk?method=sc`
   * during init. Modules read fields directly (e.g.
   * `config.serverConfig.networkingEnabled`) per the dev guide
   * §SDK Behavior Settings ConfigurationProvider interface.
   */
  public serverConfig: ServerConfig = new ServerConfig();
  /** Developer-supplied bootstrap SBS JSON (see CountlyConfig.setSDKBehaviorSettings). */
  public sdkBehaviorSettings: string | null = null;
  /** Disable the periodic + init-time SBS fetch (see CountlyConfig.disableSDKBehaviorSettingsUpdates). */
  public sdkBehaviorSettingsRequestsDisabled: boolean = false;

  /** Experimental sub-config, mirrors dev guide §Experimental. */
  public experimentalVisibilityTracking: boolean = false;
  public experimentalPreviousNameRecording: boolean = false;

  constructor() {
    this.network = new Network(this.logger);
  }
}
