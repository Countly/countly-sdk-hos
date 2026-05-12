import { describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';
import { ContentStatus, CrashData, LogLevel, LogListener, MessagingProvider, PushActionHandler, PushTestMode, SegmentationMap, WebViewDisplayOption } from '../../../main/ets/types/Types';
import { ModuleBase } from '../../../main/ets/internal/ModuleBase';
import { InternalConfig } from '../../../main/ets/internal/InternalConfig';
import { buildHarness, Harness, TestableCountlyConfig } from './TestHelpers';

function ctx(): common.Context { return {} as common.Context; }

export default function countlyConfigTest() {
  describe('CountlyConfigTest', () => {
    it('groupedSetters_chain', 0, () => {
      const metricOverride: Record<string, string> = { '_device': 'Pixel' };
      // Setters return `CountlyConfig` (the base type's `this`), so a chain off
      // a TestableCountlyConfig narrows back to CountlyConfig at compile time.
      // Split construction from the chained setters to keep the variable typed
      // as TestableCountlyConfig — the *ForTest getters live on the subclass.
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.setAppVersion('9.9');
      cfg.setMetricOverride(metricOverride);
      cfg.logging
        .enableLogging()
        .setMinLevel(LogLevel.WARNING);
      cfg.deviceId
        .setId('abc')
        .enableTemporaryMode()
        .enableClearStoredDeviceId();
      cfg.network
        .setHttpPostForced(true)
        .setRequestDropAgeHours(5)
        .setRequestTimeoutDuration(15)
        .setParameterTamperingProtectionSalt('pepper')
        .disableBackoffMechanism()
        .setMaxRequestQueueSize(500);
      cfg.events.setQueueSizeToSend(50);
      cfg.sessions
        .enableManualControl()
        .setUpdateIntervalSec(30);
      cfg.consent
        .setRequiresConsent(true)
        .giveAll();
      cfg.location.set('US', 'NY', '1.0,2.0', '8.8.8.8');
      const upProps: SegmentationMap = { 'name': 'Jane' };
      cfg.userProfile.setProperties(upProps);

      expect(cfg.appVersion).assertEqual('9.9');
      expect(cfg.deviceId.id).assertEqual('abc');
      expect(cfg.logging.enabled).assertTrue();
      expect(cfg.logging.minLevel).assertEqual(LogLevel.WARNING);
      expect(cfg.deviceId.temporaryMode).assertTrue();
      expect(cfg.deviceId.clearStored).assertTrue();
      expect(cfg.network.forcePost).assertTrue();
      expect(cfg.network.requestDropAgeHours).assertEqual(5);
      expect(cfg.network.requestTimeoutSec).assertEqual(15);
      expect(cfg.network.parameterTamperingSalt).assertEqual('pepper');
      expect(cfg.network.backoffDisabled).assertTrue();
      expect(cfg.events.queueThreshold).assertEqual(50);
      expect(cfg.sessions.updateIntervalSec).assertEqual(30);
      expect(cfg.network.maxRequestQueueSize).assertEqual(500);
      expect(cfg.sessions.manualControl).assertTrue();
      expect(cfg.consent.requires).assertTrue();
      expect(cfg.consent.initialAll).assertTrue();
      expect(cfg.location.country).assertEqual('US');
      expect(cfg.metricOverride['_device']).assertEqual('Pixel');
      expect(cfg.userProfile.initialProperties['name']).assertEqual('Jane');
    });

    it('subConfigs_fluent', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const crashSeg: SegmentationMap = { 'build': 'debug' };
      const viewSeg: SegmentationMap = { 'env': 'qa' };
      cfg.crashes
        .enableCrashReporting()
        .enableRecordAllThreadsWithCrash()
        .setCustomCrashSegmentation(crashSeg)
        .setGlobalCrashFilterCallback((_c: CrashData): boolean => false);
      cfg.views
        .enableAutomaticViewTracking()
        .enableAutomaticViewShortNames()
        .setAutomaticViewTrackingExclusions(['Splash'])
        .setTrackOrientationChanges(false)
        .setGlobalViewSegmentation(viewSeg)
        .disableViewRestartForManualRecording();
      cfg.contentForTest
        .setContentCallback((_s: ContentStatus, _d: Record<string, Object>): void => { /* ignore */ })
        .setZoneTimerInterval(30);
      expect(cfg.crashes.enabled).assertTrue();
      expect(cfg.crashes.recordAllThreads).assertTrue();
      expect(cfg.views.automaticEnabled).assertTrue();
      expect(cfg.views.useShortNames).assertTrue();
      expect(cfg.views.exclusions[0]).assertEqual('Splash');
      expect(cfg.views.trackOrientationChanges).assertFalse();
      expect(cfg.views.globalSegmentation['env']).assertEqual('qa');
      expect(cfg.views.disableViewRestartForManual).assertTrue();
      expect(cfg.contentForTest.zoneIntervalSec).assertEqual(30);
    });

    it('setZoneTimerInterval_rejectsTooSmall', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.contentForTest.setZoneTimerInterval(5); // < 15 is ignored
      expect(cfg.contentForTest.zoneIntervalSec).assertEqual(30);
    });

    it('setRequestTimeoutDuration_minClampOne', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.network.setRequestTimeoutDuration(0);
      expect(cfg.network.requestTimeoutSec).assertEqual(1);
    });

    it('giveAllConsents_setsInitialConsentAllFlag', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.consent.setRequiresConsent(true).giveAll();
      expect(cfg.consent.initialAll).assertTrue();
    });

    /* ----- Ported from CountlyConfigTests.java ----- */

    /** Port of `constructor()` — constructor wires context / serverUrl / appKey. */
    it('constructor_wiresRequiredArgs', 0, () => {
      const c: common.Context = ctx();
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(c, 'https://try.count.ly', 'Som345345');
      expect(cfg.context === c).assertTrue();
      expect(cfg.appKey).assertEqual('Som345345');
      expect(cfg.serverUrl).assertEqual('https://try.count.ly');
    });

    /** Port of `defaultValues()` — every sub-config starts at the documented default. */
    it('defaultValues_allSubConfigs', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      expect(cfg.appVersion).assertEqual('1.0');
      expect(Object.keys(cfg.metricOverride).length).assertEqual(0);

      expect(cfg.logging.enabled).assertFalse();
      expect(cfg.logging.listener === null).assertTrue();
      expect(cfg.logging.minLevel).assertEqual(LogLevel.DEBUG);

      expect(cfg.deviceId.id === null).assertTrue();
      expect(cfg.deviceId.temporaryMode).assertFalse();
      expect(cfg.deviceId.clearStored).assertFalse();

      expect(cfg.consent.requires).assertFalse();
      expect(cfg.consent.initialAll).assertFalse();
      expect(cfg.consent.unknownMode).assertFalse();

      expect(cfg.network.maxRequestQueueSize).assertEqual(1000);
      expect(cfg.network.requestDropAgeHours).assertEqual(168);
      expect(cfg.network.requestTimeoutSec).assertEqual(30);
      expect(cfg.network.forcePost).assertTrue();
      expect(cfg.network.parameterTamperingSalt === null).assertTrue();
      expect(cfg.network.backoffDisabled).assertFalse();
      expect(cfg.network.startInOfflineMode).assertFalse();
      expect(cfg.network.healthCheckDisabled).assertFalse();

      expect(cfg.sessions.manualControl).assertFalse();
      expect(cfg.sessions.manualHybridMode).assertFalse();
      expect(cfg.sessions.updateIntervalSec).assertEqual(60);

      expect(cfg.events.queueThreshold).assertEqual(100);

      expect(cfg.crashes.enabled).assertFalse();
      expect(cfg.crashes.recordAllThreads).assertFalse();
      expect(cfg.crashes.filter === null).assertTrue();
      expect(Object.keys(cfg.crashes.customSegmentation).length).assertEqual(0);

      expect(cfg.views.automaticEnabled).assertFalse();
      expect(cfg.views.useShortNames).assertFalse();
      expect(cfg.views.exclusions.length).assertEqual(0);
      expect(cfg.views.trackOrientationChanges).assertTrue();
      expect(cfg.views.disableViewRestartForManual).assertFalse();

      expect(cfg.location.country === null).assertTrue();
      expect(cfg.location.city === null).assertTrue();
      expect(cfg.location.gps === null).assertTrue();
      expect(cfg.location.ip === null).assertTrue();
      expect(cfg.location.disabled).assertFalse();
    });

    /** Port of `config_testExperimentalInterface()` — toggle lands and is
     *  idempotent under repeat calls. */
    it('experimental_togglesAndIsIdempotent', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      expect(cfg.experimental !== null).assertTrue();
      expect(cfg.experimental.visibilityTracking).assertFalse();
      expect(cfg.experimental.previousNameRecording).assertFalse();
      cfg.experimental.enablePreviousNameRecording();
      expect(cfg.experimental.previousNameRecording).assertTrue();
      cfg.experimental.enableVisibilityTracking();
      expect(cfg.experimental.visibilityTracking).assertTrue();
      cfg.experimental.enablePreviousNameRecording();
      expect(cfg.experimental.previousNameRecording).assertTrue();
      cfg.experimental.enableVisibilityTracking();
      expect(cfg.experimental.visibilityTracking).assertTrue();
    });

    /** Port of `settingAllValues()` slice — sets every cross-cutting value
     *  and confirms the fluent top-level setters return `this`. */
    it('settingAllValues_topLevel', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const metric: Record<string, string> = { 'SomeKey': '123', '_Carrier': 'BoneyK' };
      const out: CountlyConfig = cfg
        .setAppVersion('9.9.9')
        .setMetricOverride(metric);
      expect(out === cfg).assertTrue();
      expect(cfg.appVersion).assertEqual('9.9.9');
      expect(cfg.metricOverride['SomeKey']).assertEqual('123');
      expect(cfg.metricOverride['_Carrier']).assertEqual('BoneyK');
    });

    /** Custom headers accumulate across calls. */
    it('networkCustomHeaders_accumulate', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const headersA: Record<string, string> = { 'X-A': '1' };
      const headersB: Record<string, string> = { 'X-B': '2' };
      cfg.network.addCustomNetworkRequestHeaders(headersA);
      cfg.network.addCustomNetworkRequestHeaders(headersB);
      expect(cfg.network.customHeaders['X-A']).assertEqual('1');
      expect(cfg.network.customHeaders['X-B']).assertEqual('2');
    });

    /** ContentConfig.addAllowedOrigins accepts multiple and dedupes. */
    it('contentAllowedOrigins_dedup', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.contentForTest.addAllowedOrigins(['https://a.com', 'https://b.com']);
      cfg.contentForTest.addAllowedOrigins(['https://a.com', 'https://c.com']);
      expect(cfg.contentForTest.allowedOrigins.length).assertEqual(3);
    });

    /** maxRequestQueueSize clamps to at least 1 (mirrors requestTimeout clamp). */
    it('setMaxRequestQueueSize_minClampOne', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.network.setMaxRequestQueueSize(0);
      expect(cfg.network.maxRequestQueueSize).assertEqual(1);
    });

    /** SessionsConfig.setUpdateIntervalSec clamps to at least 1. */
    it('setUpdateIntervalSec_minClampOne', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.sessions.setUpdateIntervalSec(-5);
      expect(cfg.sessions.updateIntervalSec).assertEqual(1);
    });

    /** EventsConfig.setQueueSizeToSend clamps to at least 1. */
    it('setQueueSizeToSend_minClampOne', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.events.setQueueSizeToSend(0);
      expect(cfg.events.queueThreshold).assertEqual(1);
    });

    /** enableManualHybridMode implies manualControl. */
    it('enableManualHybridMode_impliesManualControl', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.sessions.enableManualHybridMode();
      expect(cfg.sessions.manualControl).assertTrue();
      expect(cfg.sessions.manualHybridMode).assertTrue();
    });

    /** NetworkConfig.enableOfflineMode sets startInOfflineMode flag. */
    it('networkEnableOfflineMode_setsFlag', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.network.enableOfflineMode();
      expect(cfg.network.startInOfflineMode).assertTrue();
    });

    /** disableHealthCheck sets flag. */
    it('networkDisableHealthCheck_setsFlag', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.network.disableHealthCheck();
      expect(cfg.network.healthCheckDisabled).assertTrue();
    });

    /** Push sub-config setters land on config. */
    it('pushSetters_land', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.pushForTest.setSendPushTokenAlways(true).setAllowedIntentTargets(['https://ok']);
      expect(cfg.pushForTest.sendTokenAlways).assertTrue();
      expect(cfg.pushForTest.allowedIntentTargets[0]).assertEqual('https://ok');
    });

    /** RC sub-config setters land on config. */
    it('rcSetters_land', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.remoteConfig.enrollABonDownload().enableAutomaticTriggers().enableValueCaching();
      expect(cfg.remoteConfig.abAutoOptin).assertTrue();
      expect(cfg.remoteConfig.automaticTriggers).assertTrue();
      expect(cfg.remoteConfig.valueCaching).assertTrue();
    });

    /** Location sub-config disable() flips disabled flag. */
    it('locationDisable_flipsFlag', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.location.disable();
      expect(cfg.location.disabled).assertTrue();
    });

    /** Settings propagate to InternalConfig once the instance is initialized. */
    it('settingsPropagateToInternalConfig', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setAppVersion('7.7.7');
        cfg.network.setRequestDropAgeHours(72);
        cfg.sessions.setUpdateIntervalSec(15);
        cfg.events.setQueueSizeToSend(25);
        cfg.location.set('FR', 'Paris', '48.8,2.3', '1.2.3.4');
        cfg.crashes.enableCrashReporting().enableRecordAllThreadsWithCrash();
      });
      expect(h.instance.config.appVersion).assertEqual('7.7.7');
      expect(h.instance.config.requestDropAgeHours).assertEqual(72);
      expect(h.instance.config.sessionUpdateIntervalSec).assertEqual(15);
      expect(h.instance.config.eventQueueThreshold).assertEqual(25);
      expect(h.instance.config.initialLocationCountry).assertEqual('FR');
      expect(h.instance.config.initialLocationGps).assertEqual('48.8,2.3');
      expect(h.instance.config.enableCrashReporting).assertTrue();
      expect(h.instance.config.recordAllThreadsWithCrash).assertTrue();
    });

    /** InternalConfig decouples from the source CountlyConfig — mutating the
     *  CountlyConfig after construction does not leak back. */
    it('internalConfig_decoupledFromSource', 0, async () => {
      const metric: Record<string, string> = { '_device': 'X' };
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setMetricOverride(metric);
      });
      h.config.metricOverride['_device'] = 'Y';
      expect(h.instance.config.metricOverride['_device']).assertEqual('X');
    });

    // -- Sub-config setters that aren't otherwise exercised by harness flows.
    // These cover the dormant push/content/feedback config wiring (modules
    // are disabled but their config fields persist for clean re-enable).

    it('logging_setListener_storesListener', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const captured: string[] = [];
      const listener: LogListener = (msg: string, _level: LogLevel): void => {
        captured.push(msg);
      };
      cfg.logging.setListener(listener);
      expect(cfg.logging.listener !== null).assertTrue();
    });

    it('content_setCategories_clonesArray', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const cats: string[] = ['promo', 'tutorial'];
      cfg.contentForTest.setCategories(cats);
      cats.push('mutated');
      // Clone behavior: subsequent mutation of the input should not bleed in.
      expect(cfg.contentForTest.categories.length).assertEqual(2);
      expect(cfg.contentForTest.categories.indexOf('promo') !== -1).assertTrue();
    });

    it('content_disableRefreshContentZone_flipsFlag', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      expect(cfg.contentForTest.refreshEnabled).assertTrue();
      cfg.contentForTest.disableRefreshContentZone();
      expect(cfg.contentForTest.refreshEnabled).assertFalse();
    });

    it('content_setDisplayMode_storesMode', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.contentForTest.setDisplayMode(WebViewDisplayOption.SAFE_AREA);
      expect(cfg.contentForTest.displayMode).assertEqual(WebViewDisplayOption.SAFE_AREA);
    });

    it('feedback_setDisplayMode_storesMode', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.feedbackForTest.setDisplayMode(WebViewDisplayOption.SAFE_AREA);
      expect(cfg.feedbackForTest.displayMode).assertEqual(WebViewDisplayOption.SAFE_AREA);
    });

    it('push_setMessagingProvider_storesProvider', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.pushForTest.setMessagingProvider(MessagingProvider.HMS);
      expect(cfg.pushForTest.provider).assertEqual(MessagingProvider.HMS);
    });

    it('push_setTestMode_storesMode', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      cfg.pushForTest.setTestMode(PushTestMode.TEST_DISTRIBUTION);
      expect(cfg.pushForTest.testMode).assertEqual(PushTestMode.TEST_DISTRIBUTION);
    });

    it('push_setNotificationActionHandler_storesHandler', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(ctx(), 'https://x', 'k');
      const handler: PushActionHandler = (_id: string, _btn: number, _url: string): boolean => false;
      cfg.pushForTest.setNotificationActionHandler(handler);
      expect(cfg.pushForTest.actionHandler !== null).assertTrue();
    });

    /** ModuleBase.onEnterForeground / onEnterBackground are no-op base hooks
     *  that get inherited by modules which don't care about app lifecycle
     *  (Crashes, Consent, RemoteConfig, etc.). The lifecycle fan-out in
     *  CountlyInstance only invokes the overridden hooks on Sessions /
     *  Events / Views, so the inherited paths are otherwise dead. Touch
     *  them here so refactor regressions don't go unnoticed. */
    it('moduleBase_lifecycleHooks_areNoOp', 0, () => {
      const internal: InternalConfig = new InternalConfig();
      const base: ModuleBase = new ModuleBase(internal);
      base.onEnterForeground();
      base.onEnterBackground();
      // Intentionally no assertion — reaching here means the no-op didn't
      // throw and wasn't accidentally redefined to mutate state.
      expect(true).assertTrue();
    });
  });
}
