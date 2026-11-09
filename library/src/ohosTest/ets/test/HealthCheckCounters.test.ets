import { afterEach, describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import { Countly } from '../../../main/ets/Countly';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { HttpResult } from '../../../main/ets/internal/Network';
import { Logger } from '../../../main/ets/internal/Logger';
import { ModuleCrashes } from '../../../main/ets/internal/modules/ModuleCrashes';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork, RecordedCall } from './doubles/FakeNetwork';
import { clearTestHarnesses, flushTick, TestableCountlyConfig } from './TestHelpers';

/** A FakeNetwork that can hold the next health check request until it is released. */
class GatedNetwork extends FakeNetwork {
  private gate: Promise<void> | null = null;
  private release: (() => void) | null = null;

  constructor(logger: Logger) {
    super(logger);
  }

  /** Makes the next health check request wait until `releaseHealthCheck` is called. */
  public holdNextHealthCheck(): void {
    this.gate = new Promise<void>((resolve: () => void) => {
      this.release = resolve;
    });
  }

  /** Lets the held health check request continue. */
  public releaseHealthCheck(): void {
    if (this.release !== null) {
      this.release();
      this.release = null;
    }
  }

  public override async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    if (this.gate !== null && data.indexOf('hc=') !== -1) {
      const held: Promise<void> = this.gate;
      this.gate = null;
      await held;
    }
    return super.execute(baseUrl, endpoint, data, usePost);
  }
}

/** A FakeNetwork that answers the behavior settings fetch late and refuses the queued test request. */
class SlowSettingsNetwork extends FakeNetwork {
  public refuseWith: number = 0;

  constructor(logger: Logger) {
    super(logger);
  }

  public override async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    if (endpoint === '/o/sdk') await flushTick(150);
    if (this.refuseWith > 0 && data.indexOf('foo=queued') !== -1) {
      this.calls.push({ endpoint, data, usePost, baseUrl });
      return { statusCode: this.refuseWith, body: 'refused while starting', elapsedMs: 20 };
    }
    return super.execute(baseUrl, endpoint, data, usePost);
  }
}

/** Starts an instance on the given storage and network, as one launch of the app. */
async function launch(
  storage: InMemoryStorage,
  network: FakeNetwork,
  configure?: (cfg: TestableCountlyConfig) => void
): Promise<CountlyInstance> {
  const cfg: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
  cfg.logging.enableLogging();
  if (configure) configure(cfg);
  const instance: CountlyInstance = new CountlyInstance(cfg, storage, network);
  await instance.init();
  return instance;
}

/** The URL-decoded health check request, or '' when none was sent. */
function healthCheckBody(network: FakeNetwork): string {
  const hc: RecordedCall | undefined = network.calls.find((c: RecordedCall) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
  return hc === undefined ? '' : decodeURIComponent(hc.data);
}

/** The health check state the instance stored, parsed. */
function storedState(storage: InMemoryStorage): Record<string, Object> {
  const raw: string | undefined = storage.dump()['HEALTH_CHECK'];
  if (raw === undefined || raw.length === 0) return {} as Record<string, Object>;
  return JSON.parse(raw) as Record<string, Object>;
}

export default function healthCheckCountersTest() {
  describe('HealthCheckCountersTest', () => {
    afterEach((): void => { clearTestHarnesses(); });

    it('ackedHealthCheck_keepsCountsMadeWhileItWasOnItsWay', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const first: GatedNetwork = new GatedNetwork(logger);
      first.holdNextHealthCheck();
      const a: CountlyInstance = await launch(storage, first);
      await flushTick(40);
      a.config.logger.e('error while the health check is on its way');
      a.config.logger.e('second error while the health check is on its way');
      first.releaseHealthCheck();
      await flushTick(60);
      await a.stop();

      const second: FakeNetwork = new FakeNetwork(logger);
      const b: CountlyInstance = await launch(storage, second);
      await flushTick(80);
      const el: RegExpMatchArray | null = healthCheckBody(second).match(/"el":(\d+)/);
      expect(el !== null && parseInt(el[1]) >= 2).assertTrue();
      await b.stop();
    });

    it('retryPauseAfterServerError_isNotCountedAsBackoff', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network);
      await flushTick(60);
      network.nextStatus = 500;
      network.nextBody = 'Internal Server Error';
      await a.requestQueue.enqueue(`timestamp=${Date.now()}&foo=server_error`);
      await flushTick(120);
      await a.stop();
      const state: Record<string, Object> = storedState(storage);
      expect(state['BReq'] as number).assertEqual(0);
      expect(state['RStatC'] as number).assertEqual(500);
    });

    it('slowServerBackoffsInARow_raiseLongestRun', 0, async () => {
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'bom_at': 1, 'bom_d': 1, 'bom_rqp': 0.9 } as Record<string, Object>
      });
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.setSDKBehaviorSettings(sbs); });
      await flushTick(60);
      network.nextElapsedMs = 1500;
      await a.requestQueue.enqueue(`timestamp=${Date.now()}&foo=slow1`);
      await flushTick(150);
      await a.requestQueue.enqueue(`timestamp=${Date.now()}&foo=slow2`);
      await flushTick(1400);
      await a.stop();
      const state: Record<string, Object> = storedState(storage);
      expect(state['BReq'] as number).assertEqual(2);
      expect(state['CBReq'] as number).assertEqual(2);
      expect(JSON.stringify(state['LC'])).assertEqual('{"w320":2,"w321":1}');
    });

    it('methodUsage_skipsFeaturesWithoutConsent', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.consent.setRequiresConsent(true); });
      await flushTick(60);
      a.consentModule.giveConsent(['events']);
      a.events.startEvent('with_consent');
      a.views.pauseViewWithID('no_such_view');
      await a.stop();
      const state: Record<string, Object> = storedState(storage);
      expect(JSON.stringify(state['MU'])).assertEqual('{"events":{"start":1}}');
      expect(JSON.stringify(state['LC'])).assertEqual('{}');
    });

    it('methodUsageAndLogCodes_surviveAFailedSendAndARestart', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const first: FakeNetwork = new FakeNetwork(logger);
      first.shouldFail = true;
      const a: CountlyInstance = await launch(storage, first);
      await flushTick(60);
      a.events.cancelEvent('never_started');
      await a.stop();

      const second: FakeNetwork = new FakeNetwork(logger);
      const b: CountlyInstance = await launch(storage, second);
      await flushTick(80);
      const body: string = healthCheckBody(second);
      expect(body.indexOf('"events":{"cancel":1}') !== -1).assertTrue();
      expect(body.indexOf('"w721":1') !== -1).assertTrue();
      await b.stop();
    });

    it('storedAutomaticCrashCount_isReportedAsRecordAOnce', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      await storage.setString('HEALTH_CHECK_AUTOMATIC_CRASHES', '2');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network);
      await flushTick(80);
      expect(healthCheckBody(network).indexOf('"crashes":{"record:a":2}') !== -1).assertTrue();
      expect(storage.dump()['HEALTH_CHECK_AUTOMATIC_CRASHES']).assertEqual('0');
      await a.stop();
    });

    it('malformedStoredState_isResetAndCountedAsE503', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      await storage.setString('HEALTH_CHECK', '{not json');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network);
      await flushTick(80);
      expect(healthCheckBody(network).indexOf('"lc":{"e503":1}') !== -1).assertTrue();
      await a.stop();
    });

    it('withoutMetricsConsent_healthCheckHasNoAppVersion', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.consent.setRequiresConsent(true); });
      await flushTick(80);
      const body: string = healthCheckBody(network);
      expect(body.length > 0).assertTrue();
      expect(body.indexOf('metrics=') === -1).assertTrue();
      await a.stop();
    });

    it('networkingOffBySettings_sendsNoHealthCheck', 0, async () => {
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'networking': false } as Record<string, Object>
      });
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(sbs);
        cfg.disableSDKBehaviorSettingsUpdates();
      });
      await flushTick(80);
      expect(healthCheckBody(network)).assertEqual('');
      await a.stop();
    });

    it('temporaryIdReplaced_sendsTheDeferredHealthCheck', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.deviceId.enableTemporaryMode(); });
      await flushTick(80);
      expect(healthCheckBody(network)).assertEqual('');
      await a.deviceId.setID('real_id_after_temporary');
      await flushTick(80);
      expect(healthCheckBody(network).indexOf('device_id=real_id_after_temporary') !== -1).assertTrue();
      await a.stop();
    });

    it('automaticCrash_countingResumesOnceTheReportIsRecorded', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network);
      await flushTick(60);
      const crashes: ModuleCrashes = new ModuleCrashes(a.config, a);
      crashes.handleUnhandledException('Error: automatic crash for the health check\n    at test (Test.ets:1:1)');
      await flushTick(150);
      a.events.startEvent('after_the_crash');
      await a.stop();
      expect(JSON.stringify(storedState(storage)['MU']).indexOf('"events":{"start":1}') !== -1).assertTrue();
    });

    it('unknownConsentRefused_healthCheckCarriesNoUsageAndNoAppVersion', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.consent.enableUnknownConsentMode(); });
      await flushTick(60);
      a.events.startEvent('during_unknown_consent');
      a.views.pauseViewWithID('no_such_view');
      a.consent.removeConsentAll();
      await flushTick(200);
      const body: string = healthCheckBody(network);
      expect(body.length > 0).assertTrue();
      expect(body.indexOf('metrics=') === -1).assertTrue();
      expect(body.indexOf('"fu":{}') !== -1).assertTrue();
      expect(body.indexOf('"lc":{}') !== -1).assertTrue();
      await a.stop();
    });

    it('failureBeforeStoredStateIsRead_isNotOverwrittenByIt', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const offline: FakeNetwork = new FakeNetwork(logger);
      offline.shouldFail = true;
      const a: CountlyInstance = await launch(storage, offline);
      await flushTick(60);
      await a.requestQueue.enqueue(`timestamp=${Date.now()}&foo=queued`);
      await flushTick(60);
      await a.stop();

      const network: SlowSettingsNetwork = new SlowSettingsNetwork(logger);
      network.refuseWith = 500;
      const b: CountlyInstance = await launch(storage, network);
      await flushTick(80);
      expect(healthCheckBody(network).indexOf('"sc":500') !== -1).assertTrue();
      await b.stop();
    });

    it('offlineMode_holdsTheHealthCheckUntilItEnds', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network, (cfg: TestableCountlyConfig) => { cfg.network.enableOfflineMode(); });
      await flushTick(80);
      expect(healthCheckBody(network)).assertEqual('');
      await a.requests.disableOfflineMode();
      await flushTick(80);
      expect(healthCheckBody(network).length > 0).assertTrue();
      await a.stop();
    });

    it('repeatedInitShared_isCountedAsW110', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = await Countly.initShared(cfg, storage, network);
      const b: CountlyInstance = await Countly.initShared(cfg, storage, network);
      await flushTick(80);
      expect(a === b).assertTrue();
      expect(healthCheckBody(network).indexOf('"w110":1') !== -1).assertTrue();
      await Countly.haltAll();
    });

    it('repeatedCreateInstance_isCountedAsW110', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = await Countly.createInstance('hc_repeat', cfg, storage, network);
      const b: CountlyInstance = await Countly.createInstance('hc_repeat', cfg, storage, network);
      await flushTick(80);
      expect(a === b).assertTrue();
      expect(healthCheckBody(network).indexOf('"w110":1') !== -1).assertTrue();
      await Countly.haltAll();
    });

    it('negativeDuration_isCountedAsW750', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launch(storage, network);
      await flushTick(60);
      await a.events.recordEvent('negative_duration', null, 1, 0, -5);
      await a.stop();
      expect(JSON.stringify(storedState(storage)['LC'])).assertEqual('{"w750":1}');
    });
  });
}
