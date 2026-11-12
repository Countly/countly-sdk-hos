import { afterEach, describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import {
  buildHarness,
  flushTick,
  Harness,
  TestableCountlyConfig,
  assertAllRecordedCallsValid,
  clearTestHarnesses,
  assertWireOrder,
  parseQueryParams
} from './TestHelpers';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { HttpResult } from '../../../main/ets/internal/Network';
import { Logger } from '../../../main/ets/internal/Logger';
import { LogLevel, RCData } from '../../../main/ets/types/Types';
import { FakeNetwork, RecordedCall } from './doubles/FakeNetwork';
import { InMemoryStorage } from './doubles/InMemoryStorage';

/** A FakeNetwork that answers remote config downloads with `rcBody`. */
class AppKeyNetwork extends FakeNetwork {
  public rcBody: string = '{}';

  constructor(logger: Logger) {
    super(logger);
  }

  public override async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    if (endpoint === '/o/sdk' && data.indexOf('method=rc') !== -1) {
      this.calls.push({ endpoint, data, usePost, baseUrl });
      return { statusCode: 200, body: this.rcBody, elapsedMs: 20 };
    }
    return super.execute(baseUrl, endpoint, data, usePost);
  }
}

/** Starts an instance on the given storage and network, as one launch of the app. */
async function launchOn(
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

/** The app key a recorded request was sent with. */
function keyOf(call: RecordedCall): string {
  return parseQueryParams(call.data)['app_key'];
}

/** The recorded requests whose decoded data contains `text`, in the order they were sent. */
function callsWith(network: FakeNetwork, text: string): RecordedCall[] {
  return network.calls.filter((c: RecordedCall) => decodeURIComponent(c.data).indexOf(text) !== -1);
}

/** The start of a view, as `[CLY]_view` segmentation. */
function viewStart(name: string): string {
  return `"name":"${name}","segment":"HarmonyOS","visit":"1"`;
}

/** The stop of a view, as `[CLY]_view` segmentation. */
function viewStop(name: string): string {
  return `"segmentation":{"name":"${name}"}`;
}

/** The behavior settings fetches and remote config downloads that were sent. */
function fetches(network: FakeNetwork, method: string): RecordedCall[] {
  return network.calls.filter((c: RecordedCall) => c.endpoint === '/o/sdk' && c.data.indexOf(`method=${method}`) !== -1);
}

/** The health check log codes the instance stored, as JSON. */
function storedLogCodes(storage: InMemoryStorage): string {
  const raw: string | undefined = storage.dump()['HEALTH_CHECK'];
  if (raw === undefined || raw.length === 0) return '';
  return JSON.stringify((JSON.parse(raw) as Record<string, Object>)['LC']);
}

export default function appKeyTest() {
  describe('AppKeyTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('changeAppKey_closesTheOldAppThenContinuesUnderTheNewKey', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.views.startView('Home');
      await h.instance.events.recordEvent('before_change');
      h.instance.events.startEvent('timed_across');
      h.instance.userProfile.setProperty('plan', 'pro');
      const deviceId: string = h.instance.deviceId.getID();
      h.network.reset();

      await h.instance.changeAppKey('new_app_key');
      await flushTick(120);

      expect(h.instance.config.appKey).assertEqual('new_app_key');
      expect(h.instance.deviceId.getID()).assertEqual(deviceId);
      // The old app gets its events, the profile changes and the end of its session before the new session begins.
      assertWireOrder(h.network.calls, ['before_change', 'user_details=', 'end_session=1', 'begin_session=1']);
      expect(keyOf(callsWith(h.network, 'before_change')[0])).assertEqual('test_app_key');
      expect(keyOf(callsWith(h.network, 'user_details=')[0])).assertEqual('test_app_key');
      expect(keyOf(callsWith(h.network, viewStop('Home'))[0])).assertEqual('test_app_key');
      expect(keyOf(callsWith(h.network, 'end_session=1')[0])).assertEqual('test_app_key');
      const begins: RecordedCall[] = callsWith(h.network, 'begin_session=1');
      expect(begins.length).assertEqual(1);
      expect(keyOf(begins[0])).assertEqual('new_app_key');
      expect(h.network.calls.every((c: RecordedCall) => parseQueryParams(c.data)['device_id'] === deviceId)).assertTrue();

      // The view starts again as the first view of the new session, and the timed event keeps running.
      await h.instance.events.endEvent('timed_across');
      await h.instance.flushEvents();
      await flushTick(60);
      const starts: RecordedCall[] = callsWith(h.network, `${viewStart('Home')},"start":"1"`);
      expect(starts.length).assertEqual(2);
      expect(keyOf(starts[0])).assertEqual('test_app_key');
      expect(keyOf(starts[1])).assertEqual('new_app_key');
      expect(keyOf(callsWith(h.network, 'timed_across')[0])).assertEqual('new_app_key');
    });

    it('changeAppKey_invalidPlaceholderOrSameKey_isIgnored', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      h.network.reset();

      await h.instance.changeAppKey('');
      await h.instance.changeAppKey('   ');
      await h.instance.changeAppKey('YOUR_APP_KEY');
      await h.instance.changeAppKey('test_app_key');
      await flushTick(60);

      expect(h.instance.config.appKey).assertEqual('test_app_key');
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(fetches(h.network, 'sc').length).assertEqual(0);
      await h.instance.saveHealthCheckState();
      expect(storedLogCodes(h.storage).indexOf('"e103":3') !== -1).assertTrue();

      await h.instance.stop();
      await h.instance.changeAppKey('after_stop');
      expect(h.instance.config.appKey).assertEqual('test_app_key');
    });

    it('changeAppKey_queuedRequestsKeepTheirKey_queueHelpersMoveOrDropThem', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(60);
      h.network.reset();
      h.instance.requestQueue.pause();
      await h.instance.events.recordEvent('evt_a');
      await h.instance.flushEvents();
      await h.instance.changeAppKey('key_b');
      await h.instance.events.recordEvent('evt_b');
      await h.instance.flushEvents();

      let queued: string[] = h.instance.requestQueue.peekAll();
      expect(queued.length).assertEqual(2);
      expect(parseQueryParams(queued[0])['app_key']).assertEqual('test_app_key');
      expect(parseQueryParams(queued[1])['app_key']).assertEqual('key_b');

      await h.instance.requests.replaceAllAppKeysInQueueWithCurrentAppKey();
      queued = h.instance.requestQueue.peekAll();
      expect(queued.every((r: string) => parseQueryParams(r)['app_key'] === 'key_b')).assertTrue();

      await h.instance.changeAppKey('key_c');
      await h.instance.events.recordEvent('evt_c');
      await h.instance.flushEvents();
      await h.instance.requests.removeDifferentAppKeysFromQueue();
      queued = h.instance.requestQueue.peekAll();
      expect(queued.length).assertEqual(1);
      expect(queued[0].indexOf('evt_c') !== -1).assertTrue();

      h.instance.requestQueue.resume();
      await flushTick(60);
      const sent: RecordedCall[] = h.network.calls.filter((c: RecordedCall) => c.endpoint === '/i');
      expect(sent.length).assertEqual(1);
      expect(keyOf(sent[0])).assertEqual('key_c');
      expect(sent[0].data.indexOf('evt_c') !== -1).assertTrue();
      // Each change fetched the behavior settings of the new app right away.
      const settings: RecordedCall[] = fetches(h.network, 'sc');
      expect(settings.length).assertEqual(2);
      expect(keyOf(settings[0])).assertEqual('key_b');
      expect(keyOf(settings[1])).assertEqual('key_c');
    });

    it('removeDifferentAppKeys_whileARequestIsOnItsWay_keepsTheNewAppsBeginSession', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launchOn(storage, network);
      await flushTick(60);
      network.reset();
      network.holdNext('begin_session=1');
      a.lifecycleForeground();
      await flushTick(30);

      await a.changeAppKey('key_b');
      await a.requests.removeDifferentAppKeysFromQueue();
      network.releaseHeld();
      await flushTick(120);

      const begins: RecordedCall[] = network.findCallsWithParam('begin_session=1');
      expect(begins.length).assertEqual(2);
      expect(keyOf(begins[0])).assertEqual('test_app_key');
      expect(keyOf(begins[1])).assertEqual('key_b');
      expect(network.findCallsWithParam('end_session=1').length).assertEqual(0);
      expect(a.requestQueue.size()).assertEqual(0);
      await a.stop();
    });

    it('changeAppKey_stopsEveryView_restartsOnlyTheOnesTheForegroundRestarts', 0, async () => {
      const noRestart: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.views.disableViewRestartForManualRecording();
      });
      noRestart.instance.lifecycleForeground();
      await flushTick(60);
      await noRestart.instance.views.startView('Manual');
      noRestart.network.reset();

      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.views.startView('Moving');
      const pausedId: string | null = await h.instance.views.startView('Paused');
      h.instance.views.pauseViewWithID(pausedId as string);
      h.network.reset();

      await noRestart.instance.changeAppKey('key_b');
      await h.instance.changeAppKey('key_b');
      await noRestart.instance.flushEvents();
      await h.instance.flushEvents();
      await flushTick(120);

      // Every running view stops for the old app, paused and non-restarting ones included.
      expect(keyOf(callsWith(noRestart.network, viewStop('Manual'))[0])).assertEqual('test_app_key');
      expect(keyOf(callsWith(h.network, viewStop('Moving'))[0])).assertEqual('test_app_key');
      expect(keyOf(callsWith(h.network, viewStop('Paused'))[0])).assertEqual('test_app_key');
      // Only the view the foreground would restart starts again, for the new app.
      const moving: RecordedCall[] = callsWith(h.network, viewStart('Moving'));
      expect(moving.length).assertEqual(2);
      expect(keyOf(moving[1])).assertEqual('key_b');
      expect(callsWith(h.network, viewStart('Paused')).every((c: RecordedCall) => keyOf(c) === 'test_app_key')).assertTrue();
      expect(callsWith(noRestart.network, viewStart('Manual')).every((c: RecordedCall) => keyOf(c) === 'test_app_key')).assertTrue();
    });

    it('changeAppKey_haltDuringTheChange_queuesStoresAndSchedulesNothingAfterIt', 0, async () => {
      const instances: CountlyInstance[] = [];
      const halts: Promise<void>[] = [];
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true).giveAll();
        cfg.remoteConfig.enableValueCaching();
        cfg.sessions.setUpdateIntervalSec(1);
        // Halts the instance while the new app's begin_session is being stored, an await inside the change.
        cfg.logging.setListener((message: string, _level: LogLevel): void => {
          if (instances.length === 1 && halts.length === 0 && message.indexOf('REQUEST ENQUEUED') !== -1
              && message.indexOf('app_key=key_b') !== -1 && message.indexOf('begin_session') !== -1) {
            halts.push(instances[0].halt());
          }
        });
      });
      instances.push(h.instance);
      h.instance.lifecycleForeground();
      await flushTick(60);
      h.network.reset();

      await h.instance.changeAppKey('key_b');
      expect(halts.length).assertEqual(1);
      await halts[0];
      await flushTick(1500);

      expect(h.storage.size()).assertEqual(0);
      expect(h.instance.hasAnyActiveTimers()).assertFalse();
      expect(fetches(h.network, 'sc').length).assertEqual(0);
      expect(fetches(h.network, 'rc').length).assertEqual(0);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    it('changeAppKey_pendingConsentChange_goesOutUnderTheOldKey', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => { cfg.consent.setRequiresConsent(true); });
      await flushTick(60);
      h.network.reset();
      h.instance.consentModule.giveConsent(['events']);
      await flushTick(20);
      expect(h.instance.consentModule.hasActiveTimers()).assertTrue();

      await h.instance.changeAppKey('key_b');
      await flushTick(1300);

      const consent: RecordedCall[] = h.network.findCallsWithParam('consent=');
      expect(consent.length).assertEqual(2);
      expect(keyOf(consent[0])).assertEqual('test_app_key');
      expect(decodeURIComponent(consent[0].data).indexOf('"events":true') !== -1).assertTrue();
      expect(keyOf(consent[1])).assertEqual('key_b');
      expect(decodeURIComponent(consent[1].data).indexOf('"events":true') !== -1).assertTrue();
      expect(h.instance.consentModule.hasActiveTimers()).assertFalse();
    });

    it('changeAppKey_catchesTheNewAppUp_consentSettingsAndRemoteConfig', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: AppKeyNetwork = new AppKeyNetwork(logger);
      network.rcBody = '{"old_flag":1}';
      const a: CountlyInstance = await launchOn(storage, network, (cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true).giveAll();
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      await flushTick(80);
      expect(a.remoteConfig.getValue('old_flag') !== null).assertTrue();
      network.reset();
      network.rcBody = '{"new_flag":2}';

      await a.changeAppKey('key_b');
      await flushTick(120);

      const consent: RecordedCall[] = network.findCallsWithParam('consent=');
      expect(consent.length).assertEqual(1);
      expect(keyOf(consent[0])).assertEqual('key_b');
      const settings: RecordedCall[] = fetches(network, 'sc');
      expect(settings.length).assertEqual(1);
      expect(keyOf(settings[0])).assertEqual('key_b');
      const downloads: RecordedCall[] = fetches(network, 'rc');
      expect(downloads.length).assertEqual(1);
      expect(keyOf(downloads[0])).assertEqual('key_b');
      expect(a.remoteConfig.getValue('old_flag') === null).assertTrue();
      expect(a.remoteConfig.getValue('new_flag') !== null).assertTrue();
      expect(a.consentModule.hasConsent('events')).assertTrue();
      await a.stop();
    });

    it('changeAppKey_withValueCaching_marksTheOldAppsValuesCached', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => { cfg.remoteConfig.enableValueCaching(); });
      await flushTick(60);
      h.network.nextBody = '{"old_flag":1}';
      await h.instance.remoteConfig.downloadAllKeys(null);
      h.network.reset();
      const before: RCData | null = h.instance.remoteConfig.getValue('old_flag');
      expect(before !== null && before.isCurrentUsersData).assertTrue();

      await h.instance.changeAppKey('key_b');
      await flushTick(60);

      const after: RCData | null = h.instance.remoteConfig.getValue('old_flag');
      expect(after !== null && !after.isCurrentUsersData).assertTrue();
      expect(fetches(h.network, 'rc').length).assertEqual(0);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    it('changeAppKey_manualSessions_endsAndBeginsOnlyARunningSession', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => { cfg.sessions.enableManualControl(); });
      await flushTick(60);
      h.network.reset();
      await h.instance.changeAppKey('key_b');
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      await h.instance.sessions.beginSession();
      await flushTick(60);
      await h.instance.changeAppKey('key_c');
      await flushTick(60);
      const begins: RecordedCall[] = h.network.findCallsWithParam('begin_session=1');
      expect(begins.length).assertEqual(2);
      expect(keyOf(begins[0])).assertEqual('key_b');
      expect(keyOf(begins[1])).assertEqual('key_c');
      const ends: RecordedCall[] = h.network.findCallsWithParam('end_session=1');
      expect(ends.length).assertEqual(1);
      expect(keyOf(ends[0])).assertEqual('key_b');
      assertWireOrder(h.network.calls, ['begin_session=1', 'end_session=1', 'begin_session=1']);

      // The app still ends the session of the new app itself.
      await h.instance.sessions.endSession();
      await flushTick(60);
      const allEnds: RecordedCall[] = h.network.findCallsWithParam('end_session=1');
      expect(allEnds.length).assertEqual(2);
      expect(keyOf(allEnds[1])).assertEqual('key_c');
    });

    it('changeAppKey_isNotStored_theNextInitUsesTheConfigKey', 0, async () => {
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const a: CountlyInstance = await launchOn(storage, network);
      const deviceId: string = a.deviceId.getID();
      await a.changeAppKey('key_b');
      expect(a.config.appKey).assertEqual('key_b');
      await a.stop();
      network.reset();

      const b: CountlyInstance = await launchOn(storage, network);
      expect(b.config.appKey).assertEqual('test_app_key');
      expect(b.deviceId.getID()).assertEqual(deviceId);
      b.lifecycleForeground();
      await flushTick(80);
      const begins: RecordedCall[] = network.findCallsWithParam('begin_session=1');
      expect(begins.length).assertEqual(1);
      expect(keyOf(begins[0])).assertEqual('test_app_key');
      await b.stop();
    });

    it('changeAppKey_twoCallsInARow_runOneAfterTheOther', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      h.network.reset();

      const first: Promise<void> = h.instance.changeAppKey('key_b');
      const second: Promise<void> = h.instance.changeAppKey('key_c');
      await first;
      await second;
      await flushTick(120);

      expect(h.instance.config.appKey).assertEqual('key_c');
      assertWireOrder(h.network.calls, ['end_session=1', 'begin_session=1', 'end_session=1', 'begin_session=1']);
      const ends: RecordedCall[] = h.network.findCallsWithParam('end_session=1');
      expect(ends.length).assertEqual(2);
      expect(keyOf(ends[0])).assertEqual('test_app_key');
      expect(keyOf(ends[1])).assertEqual('key_b');
      const begins: RecordedCall[] = h.network.findCallsWithParam('begin_session=1');
      expect(begins.length).assertEqual(2);
      expect(keyOf(begins[0])).assertEqual('key_b');
      expect(keyOf(begins[1])).assertEqual('key_c');
    });

    it('setServerURL_queuedAndLaterRequestsGoToTheNewServer', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(60);
      h.network.reset();
      h.instance.requestQueue.pause();
      await h.instance.events.recordEvent('queued_before_change');
      await h.instance.flushEvents();

      h.instance.setServerURL('https://b.example.com///');
      h.instance.setServerURL('');
      h.instance.setServerURL('not a url');
      h.instance.setServerURL('ftp://x');
      expect(h.instance.config.serverUrl).assertEqual('https://b.example.com');
      h.instance.requestQueue.resume();
      await flushTick(60);
      const queued: RecordedCall = callsWith(h.network, 'queued_before_change')[0];
      expect(queued.baseUrl).assertEqual('https://b.example.com');
      expect(keyOf(queued)).assertEqual('test_app_key');

      // With both changes, the new app's session and settings go to the new server.
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.changeAppKey('key_b');
      await flushTick(120);
      const begins: RecordedCall[] = h.network.findCallsWithParam('begin_session=1');
      expect(begins.length).assertEqual(2);
      expect(begins[1].baseUrl).assertEqual('https://b.example.com');
      expect(keyOf(begins[1])).assertEqual('key_b');
      const settings: RecordedCall[] = fetches(h.network, 'sc');
      expect(settings.length).assertEqual(1);
      expect(settings[0].baseUrl).assertEqual('https://b.example.com');
      expect(h.network.calls.every((c: RecordedCall) => c.baseUrl === 'https://b.example.com')).assertTrue();
    });
  });
}
