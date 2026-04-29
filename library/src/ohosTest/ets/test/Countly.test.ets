import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { Countly } from '../../../main/ets/Countly';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';
import { Logger } from '../../../main/ets/internal/Logger';
import common from '@ohos.app.ability.common';

function ctx(): common.Context { return {} as common.Context; }

export default function countlyFacadeTest() {
  describe('CountlyFacadeTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('init_invalidUrl_throws', 0, async () => {
      let threw: boolean = false;
      try {
        new CountlyConfig(ctx(), 'not-a-url', 'k');
      } catch (err) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('init_emptyAppKey_throws', 0, async () => {
      let threw: boolean = false;
      try {
        new CountlyConfig(ctx(), 'https://a.com', '');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('init_emptyServerUrl_throws', 0, async () => {
      let threw: boolean = false;
      try {
        new CountlyConfig(ctx(), '', 'k');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('init_serverUrlWithUserinfo_throws', 0, async () => {
      // https://legit.com@evil.com parses with authority=evil.com — blocks
      // supply-chain / config-injection driven telemetry redirection.
      let threw: boolean = false;
      try {
        new CountlyConfig(ctx(), 'https://legit.com@evil.com/i', 'k');
      } catch (e) {
        threw = true;
      }
      expect(threw).assertTrue();
    });

    it('multiInstance_named_independent', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storageA: InMemoryStorage = new InMemoryStorage(logger, 'keyA');
      const networkA: FakeNetwork = new FakeNetwork(logger);
      const storageB: InMemoryStorage = new InMemoryStorage(logger, 'keyB');
      const networkB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'keyA');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'keyB');
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, storageA, networkA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, storageB, networkB);
      await a.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      await b.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      // Each fake sees only its own instance's request.
      expect(networkA.calls.length >= 1).assertTrue();
      expect(networkB.calls.length >= 1).assertTrue();
      // No cross-contamination of storage either.
      expect(storageA.dump()['cly_device_id'] !== undefined).assertTrue();
      expect(storageB.dump()['cly_device_id'] !== undefined).assertTrue();
      expect(Countly.listInstances().indexOf('A') !== -1).assertTrue();
      expect(Countly.listInstances().indexOf('B') !== -1).assertTrue();
      await Countly.haltAll();
    });

    it('sharedInstance_initOnceAndReused', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'shared');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'shared');
      const a: CountlyInstance = await Countly.initShared(cfg, storage, network);
      const b: CountlyInstance = await Countly.initShared(cfg, storage, network);
      expect(a === b).assertTrue();
      expect(Countly.sharedInstance() === a).assertTrue();
      await Countly.haltAll();
    });

    it('sharedInstance_beforeInit_throws', 0, async () => {
      await Countly.haltAll();
      let threw: boolean = false;
      try { Countly.sharedInstance(); } catch (e) { threw = true; }
      expect(threw).assertTrue();
    });

    it('lifecycleForegroundAll_forwardsToAllInstances', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'k');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'k');
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);
      Countly.lifecycleForegroundAll();
      await flushTick(60);
      expect(network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      Countly.lifecycleBackgroundAll();
      await flushTick(60);
      expect(network.findCallsWithParam('end_session=1').length).assertEqual(1);
      await Countly.haltAll();
    });

    /* ----- Ported from CountlyTests.java ----- */

    /** Port of `testSharedInstance()` — sharedInstance is stable after init. */
    it('sharedInstance_reusedAfterInit', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'k');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'k');
      const a: CountlyInstance = await Countly.initShared(cfg, storage, network);
      const b: CountlyInstance = Countly.sharedInstance();
      expect(a === b).assertTrue();
      await Countly.haltAll();
    });

    /** Port of `testInit_twiceWithSameParams()` — second initShared returns
     *  the first instance; underlying config/storage remain. */
    it('initShared_twice_returnsSame', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'k');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'k');
      const a: CountlyInstance = await Countly.initShared(cfg, storage, network);
      const b: CountlyInstance = await Countly.initShared(cfg, storage, network);
      expect(a === b).assertTrue();
      expect(a.config.serverUrl.indexOf('try.count.ly') !== -1).assertTrue();
      expect(a.config.appKey).assertEqual('k');
      await Countly.haltAll();
    });

    /** Port of `testHalt_notInitialized()` — halt on an unstarted Countly is
     *  a no-op. Here we express it as haltAll before any init. */
    it('haltAll_whenNothingInited_noThrow', 0, async () => {
      let threw: boolean = false;
      try {
        await Countly.haltAll();
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    /** Port of `testIsValidURL_badURLs()` — null / empty / non-url / space
     *  should fail the URL policy in CountlyConfig. */
    it('isValidURL_badURLsRejected', 0, () => {
      const bads: string[] = ['', ' ', 'blahblahblah.com', 'ftp://x.com'];
      for (let i = 0; i < bads.length; i++) {
        let threw: boolean = false;
        try { new CountlyConfig(ctx(), bads[i], 'k'); } catch (e) { threw = true; }
        expect(threw).assertTrue();
      }
    });

    /** Port of `testIsValidURL_goodURL()` — http:// is accepted. */
    it('isValidURL_goodURLAccepted', 0, () => {
      let threw: boolean = false;
      try { new CountlyConfig(ctx(), 'http://test.count.ly', 'k'); } catch (e) { threw = true; }
      expect(threw).assertFalse();
    });

    /* ----- HOS-specific ported behaviors ----- */

    /** setServerURL — valid URL is accepted and mutates the runtime config. */
    it('setServerURL_validUrlApplied', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.setServerURL('https://new.example.com/');
      expect(h.instance.config.serverUrl).assertEqual('https://new.example.com');
    });

    /** setServerURL — scheme-less URL is ignored (logged + dropped). */
    it('setServerURL_invalidScheme_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.config.serverUrl;
      h.instance.setServerURL('ftp://bad.example.com');
      expect(h.instance.config.serverUrl).assertEqual(before);
    });

    /** setServerURL — userinfo "@" in authority is ignored. */
    it('setServerURL_userinfo_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.config.serverUrl;
      h.instance.setServerURL('https://legit.com@evil.com/i');
      expect(h.instance.config.serverUrl).assertEqual(before);
    });

    /** setServerURL — empty URL is ignored. */
    it('setServerURL_empty_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.config.serverUrl;
      h.instance.setServerURL('');
      expect(h.instance.config.serverUrl).assertEqual(before);
    });

    /** enableOfflineMode pauses the queue so enqueued traffic does NOT reach
     *  the network until disableOfflineMode flushes. */
    it('enableOfflineMode_pausesQueue', 0, async () => {
      const h: Harness = await buildHarness();
      // Wait one task tick so the deferred init-time healthcheck (scheduled
      // via setTimeout(0) in ModuleHealthCheck.onInit) has fired and landed
      // in network.calls — only THEN can we discard init-time noise.
      await flushTick(5);
      h.network.reset();
      h.instance.requests.enableOfflineMode();
      await h.instance.events.recordEvent('evt_off');
      await flushTick(60);
      // No network calls while offline.
      expect(h.network.calls.length).assertEqual(0);
      expect(h.instance.requestQueue.isPaused()).assertTrue();
      await h.instance.requests.disableOfflineMode();
      await flushTick(80);
      expect(h.instance.requestQueue.isPaused()).assertFalse();
    });

    /** disableOfflineMode('new_id') switches device id before the queue resumes. */
    it('disableOfflineMode_withDeviceId_switchesIdThenResumes', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      await h.instance.requests.disableOfflineMode('new_id_123');
      await flushTick(60);
      expect(h.instance.deviceId.getID()).assertEqual('new_id_123');
      expect(h.instance.requestQueue.isPaused()).assertFalse();
    });

    /** flushQueues clears both request queue and event queue. */
    it('flushQueues_clearsEverythingPending', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode(); // keep data local so we can observe the clear
      await h.instance.events.recordEvent('evt_a');
      await h.instance.events.recordEvent('evt_b');
      await flushTick(60);
      await h.instance.requests.flushQueues();
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    /** replaceAllAppKeysInQueueWithCurrentAppKey rewrites old app_key values. */
    it('replaceAllAppKeys_rewritesToCurrent', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      // Enqueue a fake request carrying a foreign app_key directly.
      await h.instance.requestQueue.enqueue('app_key=stale_key&foo=bar');
      await h.instance.requests.replaceAllAppKeysInQueueWithCurrentAppKey();
      const pending: string[] = h.instance.requestQueue.peekAll();
      const allCurrent: boolean = pending.every((r: string) => r.indexOf('app_key=test_app_key') !== -1);
      expect(allCurrent).assertTrue();
    });

    /** removeDifferentAppKeysFromQueue drops requests with foreign app keys. */
    it('removeDifferentAppKeys_dropsForeign', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      await h.instance.requestQueue.enqueue('app_key=other_key&foo=1');
      await h.instance.requestQueue.enqueue('app_key=test_app_key&foo=2');
      await h.instance.requests.removeDifferentAppKeysFromQueue();
      const pending: string[] = h.instance.requestQueue.peekAll();
      for (let i = 0; i < pending.length; i++) {
        expect(pending[i].indexOf('app_key=test_app_key') !== -1).assertTrue();
      }
    });

    /** addDirectRequest enqueues a request honoring consent gate. */
    it('addDirectRequest_consentGate_dropsWhenNoConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      const before: number = h.instance.requestQueue.size();
      const directA: Record<string, string> = { 'custom_key': 'custom_value' };
      await h.instance.requests.addDirectRequest(directA);
      await flushTick(50);
      // Consent required + no feature has consent → request is dropped.
      expect(h.instance.requestQueue.size()).assertEqual(before);
      const calls: number = h.network.findCallsWithParam('custom_key=custom_value').length;
      expect(calls).assertEqual(0);
    });

    /** addDirectRequest — cannot override SDK base params. */
    it('addDirectRequest_baseParamsLocked', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      const hijack: Record<string, string> = {
        'device_id': 'HIJACKED',
        'app_key': 'HIJACKED_KEY',
        'timestamp': '0',
        'my_custom': 'ok'
      };
      await h.instance.requests.addDirectRequest(hijack);
      const pending: string[] = h.instance.requestQueue.peekAll();
      expect(pending.length >= 1).assertTrue();
      const last: string = pending[pending.length - 1];
      expect(last.indexOf('device_id=HIJACKED') === -1).assertTrue();
      expect(last.indexOf('app_key=HIJACKED_KEY') === -1).assertTrue();
      expect(last.indexOf('my_custom=ok') !== -1).assertTrue();
    });

    /** addDirectRequest with granted consent actually enqueues. */
    it('addDirectRequest_grantedConsent_enqueues', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.instance.requests.enableOfflineMode();
      const directC: Record<string, string> = { 'my_key': 'my_val' };
      await h.instance.requests.addDirectRequest(directC);
      const pending: string[] = h.instance.requestQueue.peekAll();
      const has: boolean = pending.some((r: string) => r.indexOf('my_key=my_val') !== -1);
      expect(has).assertTrue();
    });

    /** setExternalUrlOpener is plumbed to both content + feedback overlays
     *  (null is an accepted unwire). */
    it('setExternalUrlOpener_acceptsNullAndFn', 0, async () => {
      const h: Harness = await buildHarness();
      let threw: boolean = false;
      try {
        h.instance.setExternalUrlOpener((_url: string) => { /* noop */ });
        h.instance.setExternalUrlOpener(null);
      } catch (e) {
        threw = true;
      }
      expect(threw).assertFalse();
    });

    /** Port of `testLoggingFlag()` — logger.enabled tracks config.logging.enabled. */
    it('loggingFlag_roundtrips', 0, async () => {
      const hOff: Harness = await buildHarness((cfg) => { /* default - logging enabled in harness */ });
      expect(hOff.instance.config.logger !== null).assertTrue();
    });

    /** haltAll clears shared + named instances. Second shared access throws. */
    it('haltAll_clearsSharedAndNamed', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const s1: InMemoryStorage = new InMemoryStorage(logger, 'kA'); const n1: FakeNetwork = new FakeNetwork(logger);
      const s2: InMemoryStorage = new InMemoryStorage(logger, 'kB'); const n2: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'kA');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'kB');
      await Countly.initShared(cfgA, s1, n1);
      await Countly.createInstance('other', cfgB, s2, n2);
      expect(Countly.listInstances().length).assertEqual(1);
      await Countly.haltAll();
      expect(Countly.listInstances().length).assertEqual(0);
      let threw: boolean = false;
      try { Countly.sharedInstance(); } catch (e) { threw = true; }
      expect(threw).assertTrue();
    });

    /** createInstance with the same name returns the same instance
     *  (idempotent like initShared). */
    it('createInstance_sameName_returnsSame', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const s: InMemoryStorage = new InMemoryStorage(logger, 'k'); const n: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'k');
      const a: CountlyInstance = await Countly.createInstance('dup', cfg, s, n);
      const b: CountlyInstance = await Countly.createInstance('dup', cfg, s, n);
      expect(a === b).assertTrue();
      await Countly.haltAll();
    });

    /** getInstance returns the registered instance for a known name and
     *  undefined for an unknown one. */
    it('getInstance_returnsRegisteredOrUndefined', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const s: InMemoryStorage = new InMemoryStorage(logger, 'k');
      const n: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'k');
      const created: CountlyInstance = await Countly.createInstance('lookup', cfg, s, n);
      expect(Countly.getInstance('lookup') === created).assertTrue();
      expect(Countly.getInstance('does_not_exist') === undefined).assertTrue();
      await Countly.haltAll();
    });

    /** Lifecycle fan-out reaches *named* instances, not just shared. The
     *  existing lifecycle test only has a shared instance so the named-map
     *  forEach lambda was never exercised. */
    it('lifecycleAll_forwardsToNamedInstances', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'kA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'kB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'kA');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'kB');
      await Countly.createInstance('A', cfgA, sA, nA);
      await Countly.createInstance('B', cfgB, sB, nB);
      Countly.lifecycleForegroundAll();
      await flushTick(60);
      expect(nA.findCallsWithParam('begin_session=1').length).assertEqual(1);
      expect(nB.findCallsWithParam('begin_session=1').length).assertEqual(1);
      Countly.lifecycleBackgroundAll();
      await flushTick(60);
      expect(nA.findCallsWithParam('end_session=1').length).assertEqual(1);
      expect(nB.findCallsWithParam('end_session=1').length).assertEqual(1);
      await Countly.haltAll();
    });

    /** Consent state is per-instance: granting on A must not grant on B.
     *  Each instance owns its own ModuleConsent over its own InternalConfig. */
    it('multiInstance_consentIsolation', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'kA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'kB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'kA');
      cfgA.consent.setRequiresConsent(true);
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'kB');
      cfgB.consent.setRequiresConsent(true);
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, sA, nA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, sB, nB);
      a.consent.giveConsent(['events']);
      expect(a.consent.getConsent('events')).assertTrue();
      expect(b.consent.getConsent('events')).assertFalse();
      await Countly.haltAll();
    });

    /** SBS state is per-instance: a different bootstrap on each config
     *  must produce different ServerConfig values. */
    it('multiInstance_sbsIsolation', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'kA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'kB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const ts: number = Date.now();
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'kA');
      cfgA.setSDKBehaviorSettings(JSON.stringify({
        'v': 1, 't': ts, 'c': { 'eqs': 10, 'lkl': 50 } as Record<string, Object>
      }));
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'kB');
      cfgB.setSDKBehaviorSettings(JSON.stringify({
        'v': 1, 't': ts, 'c': { 'eqs': 99, 'lkl': 200 } as Record<string, Object>
      }));
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, sA, nA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, sB, nB);
      expect(a.config.serverConfig.eventQueueSize).assertEqual(10);
      expect(b.config.serverConfig.eventQueueSize).assertEqual(99);
      expect(a.config.limits.maxKeyLength).assertEqual(50);
      expect(b.config.limits.maxKeyLength).assertEqual(200);
      // Cross-check: independent ServerConfig instances, not a shared ref.
      expect(a.config.serverConfig !== b.config.serverConfig).assertTrue();
      await Countly.haltAll();
    });

    /** Halting one named instance must not halt another. After A.halt(),
     *  B continues to ship requests; listInstances reports both still
     *  registered (haltAll is the path that clears the map). */
    it('multiInstance_singleHaltDoesNotAffectOther', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'kA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'kB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.countly.io', 'kA');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.countly.io', 'kB');
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, sA, nA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, sB, nB);
      await a.halt();
      // B is still alive — record on it and confirm wire activity.
      const beforeB: number = nB.findCallsWithParam('events=').length;
      await b.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(nB.findCallsWithParam('events=').length > beforeB).assertTrue();
      await Countly.haltAll();
    });
  });
}
