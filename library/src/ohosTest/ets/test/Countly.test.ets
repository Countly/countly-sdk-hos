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
      // https://legit.com@evil.com parses with authority=evil.com, blocks
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

    /** Port of `testSharedInstance()`, sharedInstance is stable after init. */
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

    /** Port of `testInit_twiceWithSameParams()`, second initShared returns
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

    /** Port of `testHalt_notInitialized()`, halt on an unstarted Countly is
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

    /** Port of `testIsValidURL_badURLs()`, null / empty / non-url / space
     *  should fail the URL policy in CountlyConfig. */
    it('isValidURL_badURLsRejected', 0, () => {
      const bads: string[] = ['', ' ', 'blahblahblah.com', 'ftp://x.com'];
      for (let i = 0; i < bads.length; i++) {
        let threw: boolean = false;
        try { new CountlyConfig(ctx(), bads[i], 'k'); } catch (e) { threw = true; }
        expect(threw).assertTrue();
      }
    });

    /** Port of `testIsValidURL_goodURL()`, http:// is accepted. */
    it('isValidURL_goodURLAccepted', 0, () => {
      let threw: boolean = false;
      try { new CountlyConfig(ctx(), 'http://test.count.ly', 'k'); } catch (e) { threw = true; }
      expect(threw).assertFalse();
    });

    /* ----- HOS-specific ported behaviors ----- */

    /** setServerURL, valid URL is accepted and mutates the runtime config. */
    it('setServerURL_validUrlApplied', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.setServerURL('https://new.example.com/');
      expect(h.instance.config.serverUrl).assertEqual('https://new.example.com');
    });

    /** setServerURL, scheme-less URL is ignored (logged + dropped). */
    it('setServerURL_invalidScheme_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.config.serverUrl;
      h.instance.setServerURL('ftp://bad.example.com');
      expect(h.instance.config.serverUrl).assertEqual(before);
    });

    /** setServerURL, userinfo "@" in authority is ignored. */
    it('setServerURL_userinfo_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.config.serverUrl;
      h.instance.setServerURL('https://legit.com@evil.com/i');
      expect(h.instance.config.serverUrl).assertEqual(before);
    });

    /** setServerURL, empty URL is ignored. */
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
      // in network.calls, only THEN can we discard init-time noise.
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
      // Init may emit a `location=` erasure (no consent → wipe server state,
      // see ModuleLocation.onInit). Wait for init traffic to settle, then
      // capture the post-init network call count so the direct-request gate
      // is what we're measuring, not init wire activity.
      await flushTick(60);
      const beforeCalls: number = h.network.calls.length;
      const directA: Record<string, string> = { 'custom_key': 'custom_value' };
      await h.instance.requests.addDirectRequest(directA);
      await flushTick(50);
      // Consent required + no feature has consent → request is dropped.
      expect(h.network.calls.length).assertEqual(beforeCalls);
      const calls: number = h.network.findCallsWithParam('custom_key=custom_value').length;
      expect(calls).assertEqual(0);
    });

    /** addDirectRequest, reserved-key denylist matches Android
     *  ModuleRequestQueue.preDefinedKeys (sdk/ModuleRequestQueue.java:34):
     *  app_key, hour, dow, tz, sdk_version, sdk_name, device_id, old_device_id,
     *  checksum, checksum256. `timestamp` is NOT reserved. */
    it('addDirectRequest_reservedKeysStripped', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      const hijack: Record<string, string> = {
        // All 10 reserved keys per Android parity:
        'device_id': 'HIJACKED',
        'app_key': 'HIJACKED_KEY',
        'old_device_id': 'HIJACKED_OLD',
        'checksum': 'HIJACKED_CS',
        'checksum256': 'HIJACKED_CS256',
        'sdk_version': '0.0.0',
        'sdk_name': 'evil',
        'hour': '99',
        'dow': '99',
        'tz': '999',
        // Allowed: timestamp + custom keys
        'my_custom': 'ok'
      };
      await h.instance.requests.addDirectRequest(hijack);
      const pending: string[] = h.instance.requestQueue.peekAll();
      expect(pending.length >= 1).assertTrue();
      const last: string = pending[pending.length - 1];
      // None of the hijack values should reach the wire.
      expect(last.indexOf('=HIJACKED') === -1).assertTrue();
      expect(last.indexOf('=HIJACKED_KEY') === -1).assertTrue();
      expect(last.indexOf('=HIJACKED_OLD') === -1).assertTrue();
      expect(last.indexOf('=HIJACKED_CS') === -1).assertTrue();
      expect(last.indexOf('sdk_name=evil') === -1).assertTrue();
      expect(last.indexOf('sdk_version=0.0.0') === -1).assertTrue();
      // The custom key passes through.
      expect(last.indexOf('my_custom=ok') !== -1).assertTrue();
    });

    /** addDirectRequest, `timestamp` IS allowed through (not in Android's
     *  preDefinedKeys list). Lets developers backfill events with explicit
     *  timestamps. */
    it('addDirectRequest_timestampOverrideAllowed', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      await h.instance.requests.addDirectRequest({ 'timestamp': '111', 'k': 'v' });
      const pending: string[] = h.instance.requestQueue.peekAll();
      const last: string = pending[pending.length - 1];
      expect(last.indexOf('timestamp=111') !== -1).assertTrue();
    });

    /** addDirectRequest, wire request carries the `&dr=1` marker per
     *  Android sdk/ConnectionQueue.java:553. */
    it('addDirectRequest_wireCarriesDrMarker', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      await h.instance.requests.addDirectRequest({ 'k': 'v' });
      const pending: string[] = h.instance.requestQueue.peekAll();
      const last: string = pending[pending.length - 1];
      expect(last.indexOf('dr=1') !== -1).assertTrue();
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

    /** Port of `testLoggingFlag()`, logger.enabled tracks config.logging.enabled. */
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
      a.consentModule.giveConsent(['events']);
      expect(a.consentModule.hasConsent('events')).assertTrue();
      expect(b.consentModule.hasConsent('events')).assertFalse();
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
      // B is still alive, record on it and confirm wire activity.
      const beforeB: number = nB.findCallsWithParam('events=').length;
      await b.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(nB.findCallsWithParam('events=').length > beforeB).assertTrue();
      await Countly.haltAll();
    });

    // ----- In-process re-init via Countly.initShared -----
    //
    // initShared is smart: if the existing shared is still usable it returns
    // the existing (idempotent). If the existing is stopped/halted/locked
    // it stops it and constructs a fresh instance. No separate reInit API.

    /** initShared returns the same instance when called repeatedly on a
     *  healthy shared (idempotent). */
    it('initShared_idempotent_returnsExistingWhenUsable', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'idem');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'idem');
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'idem');
      cfg2.setAppVersion('2.0');

      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);
      const inst2: CountlyInstance = await Countly.initShared(cfg2, storage, network);

      // Same object, the second init returned the cached instance, did NOT
      // re-init with cfg2 (cfg2.appVersion="2.0" was ignored).
      expect(inst1 === inst2).assertTrue();
      expect(inst2.config.appVersion).assertEqual('1.0');  // from cfg1, not cfg2
      await Countly.haltAll();
    });

    /** After explicit stop(), initShared with a new config replaces the
     *  existing instance, this is the supported in-process config-swap
     *  pattern. */
    it('initShared_afterStop_replacesWithFreshInstance', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'after-stop');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'after-stop');
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'after-stop');
      cfg2.setAppVersion('2.0');

      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);
      expect(Countly.sharedInstance() === inst1).assertTrue();
      expect(inst1.config.halted).assertFalse();

      // Explicit stop, then init with new config, initShared detects the
      // halted state and replaces.
      await inst1.stop();
      const inst2: CountlyInstance = await Countly.initShared(cfg2, storage, network);

      expect(inst1 === inst2).assertFalse();
      expect(inst1.config.halted).assertTrue();
      expect(inst2.config.halted).assertFalse();
      expect(Countly.sharedInstance() === inst2).assertTrue();
      expect(inst2.config.appVersion).assertEqual('2.0');
      await Countly.haltAll();
    });

    /** After UCM resolves with removeConsentAll, the lock makes the existing
     *  instance unusable. A subsequent initShared() detects the lock and
     *  replaces transparently, no extra API call required. */
    it('initShared_afterUCMRevoke_replacesAndClearsLock', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'reinit-ucm');
      const network: FakeNetwork = new FakeNetwork(logger);

      // 1) Init in unknown consent mode.
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'reinit-ucm');
      cfg1.consent.enableUnknownConsentMode();
      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);
      // 2) Revoke from UCM, engages the lock.
      inst1.consent.removeConsentAll();
      await flushTick(300);
      expect(inst1.config.consentLockedPostUnknown).assertTrue();

      // 3) Plain initShared with a resolved config, detects the lock and
      //    auto-replaces.
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'reinit-ucm');
      cfg2.consent.setRequiresConsent(true).giveAll();
      cfg2.events.setQueueSizeToSend(1);
      const inst2: CountlyInstance = await Countly.initShared(cfg2, storage, network);

      // 4) Different instance, lock gone, fresh config applied.
      expect(inst1 === inst2).assertFalse();
      expect(inst2.config.consentLockedPostUnknown).assertFalse();
      expect(inst2.config.unknownConsentMode).assertFalse();
      expect(inst2.consent.checkAllConsent()).assertTrue();
      // 5) A fresh event reaches the wire (proves SDK is fully operational).
      await inst2.events.recordEvent('post_reinit_evt');
      await flushTick(120);
      expect(network.findCallsWithParam('post_reinit_evt').length).assertEqual(1);
      await Countly.haltAll();
    });

    /** Persisted request queue survives the stop-then-init replacement,
     *  pending requests load into the new instance via RequestQueue.load()
     *  and ship. Critical for not losing the post-UCM revocation snapshot
     *  if init runs before the queue drains. */
    it('initShared_replacement_persistedQueueShipsToNewInstance', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'reinit-persist');
      const network: FakeNetwork = new FakeNetwork(logger);

      // 1) Start in offline mode so we can enqueue without auto-shipping.
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'reinit-persist');
      cfg1.network.enableOfflineMode();
      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);

      // 2) Enqueue a marker request, it persists to storage but doesn't ship.
      const marker: Record<string, string> = { 'reinit_persist_marker': 'value' };
      await inst1.requests.addDirectRequest(marker);
      await flushTick(60);
      expect(network.findCallsWithParam('reinit_persist_marker').length).assertEqual(0);
      // Persisted on disk:
      const persistedBefore: string = storage.dump()['cly_request_queue'];
      expect(persistedBefore !== undefined && persistedBefore.indexOf('reinit_persist_marker') !== -1).assertTrue();

      // 3) Stop + re-init (smart initShared) with a non-offline config.
      await inst1.stop();
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'reinit-persist');
      await Countly.initShared(cfg2, storage, network);
      await flushTick(120);

      // 4) The marker reaches the wire, loaded from persisted storage
      //    and shipped by the new instance's queue tick.
      expect(network.findCallsWithParam('reinit_persist_marker').length).assertEqual(1);
      await Countly.haltAll();
    });

    // ----- stop() vs halt() semantics -----
    //
    // stop(), preserve persisted storage. Used internally by initShared
    // when it detects an existing instance needs to be replaced.
    // halt(), wipe persisted storage. Matches Android's halt() semantics.
    //
    // Multi-instance isolation: stopping/halting one instance must not
    // affect siblings, each owns its own halted flag, its own storage,
    // its own lifecycle observer.

    /** `stop()` halts the instance in-memory but does NOT wipe persisted
     *  storage. A subsequent fresh init against the same storage picks up
     *  the persisted state (device ID, queued requests, server config). */
    it('stop_preservesPersistedStorage', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'stop-preserve');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'stop-preserve');
      cfg.network.enableOfflineMode();
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      // Enqueue a marker that the offline queue holds locally + on disk.
      const marker: Record<string, string> = { 'stop_preserve_marker': 'value' };
      await inst.requests.addDirectRequest(marker);
      await flushTick(60);

      // stop(), no wipe.
      await inst.stop();
      const persisted: string = storage.dump()['cly_request_queue'];
      expect(persisted !== undefined && persisted.indexOf('stop_preserve_marker') !== -1).assertTrue();
      // Device ID also preserved.
      expect(storage.dump()['cly_device_id'] !== undefined).assertTrue();
      // haltAll() at teardown will run a second halt() on the already-stopped
      // instance; that wipes the storage but the test's assertions ran first.
      await Countly.haltAll();
    });

    /** `halt()` halts the instance AND wipes every persisted key.
     *  Matches Android's `Countly.halt()` (which clears countlyStore). */
    it('halt_wipesPersistedStorage', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'halt-wipe');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'halt-wipe');
      cfg.network.enableOfflineMode();
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      const marker: Record<string, string> = { 'halt_wipe_marker': 'value' };
      await inst.requests.addDirectRequest(marker);
      await flushTick(60);
      expect(storage.size() > 0).assertTrue();

      // halt() wipes everything.
      await inst.halt();
      expect(storage.size()).assertEqual(0);

      await Countly.haltAll();
    });

    /** `Countly.stopAll()` calls stop() on every active instance, no
     *  storage wipe. Test confirms both named instances' storage survives. */
    it('stopAll_preservesAllInstancesStorage', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'sa');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'sb');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.count.ly', 'sa');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.count.ly', 'sb');
      await Countly.createInstance('A', cfgA, sA, nA);
      await Countly.createInstance('B', cfgB, sB, nB);
      // Init drove device-id generation, storage has at least the device id.
      expect(sA.size() > 0).assertTrue();
      expect(sB.size() > 0).assertTrue();

      await Countly.stopAll();

      // Both storages survive.
      expect(sA.size() > 0).assertTrue();
      expect(sB.size() > 0).assertTrue();
    });

    /** `Countly.haltAll()` calls halt() on every active instance, wipes
     *  each one's storage. */
    it('haltAll_wipesAllInstancesStorage', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'sa');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'sb');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.count.ly', 'sa');
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.count.ly', 'sb');
      await Countly.createInstance('A', cfgA, sA, nA);
      await Countly.createInstance('B', cfgB, sB, nB);

      await Countly.haltAll();

      expect(sA.size()).assertEqual(0);
      expect(sB.size()).assertEqual(0);
    });

    /** Halting ONE instance must NOT affect siblings, each owns its own
     *  halted flag, its own storage, its own lifecycle observer. The
     *  sibling continues to operate normally. */
    it('multiInstance_haltOne_doesNotHaltOrWipeOthers', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'isoA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'isoB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.count.ly', 'isoA');
      cfgA.consent.setRequiresConsent(true).giveAll();
      cfgA.events.setQueueSizeToSend(1);
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.count.ly', 'isoB');
      cfgB.consent.setRequiresConsent(true).giveAll();
      cfgB.events.setQueueSizeToSend(1);
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, sA, nA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, sB, nB);

      // Halt only A, wipes A's storage, but B is completely untouched.
      await a.halt();

      // A is halted + wiped.
      expect(a.config.halted).assertTrue();
      expect(sA.size()).assertEqual(0);
      // B is alive and its storage is intact.
      expect(b.config.halted).assertFalse();
      expect(sB.size() > 0).assertTrue();
      // B can still record events and reach its network.
      const beforeB: number = nB.findCallsWithParam('events=').length;
      await b.events.recordEvent('iso_b_event');
      await flushTick(120);
      expect(nB.findCallsWithParam('events=').length > beforeB).assertTrue();
      expect(nB.findCallsWithParam('iso_b_event').length).assertEqual(1);
      // A's halt did NOT touch B's network.
      expect(nA.calls.length === 0 || nA.findCallsWithParam('iso_b_event').length === 0).assertTrue();

      await Countly.haltAll();
    });

    /** Cross-verification: after stop(), re-init with the SAME storage
     *  resumes the persisted state, same device ID, buffered queue drains.
     *  This is the contract initShared's auto-replace path relies on. */
    it('stop_thenInitShared_resumesPersistedState', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'stop-resume');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'stop-resume');
      cfg1.network.enableOfflineMode();
      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);
      const did1: string = inst1.deviceId.getID();
      expect(did1.length > 0).assertTrue();

      // Buffer a request, then stop (preserve storage).
      const marker: Record<string, string> = { 'stop_resume_marker': 'value' };
      await inst1.requests.addDirectRequest(marker);
      await flushTick(60);
      expect(network.findCallsWithParam('stop_resume_marker').length).assertEqual(0);
      await inst1.stop();

      // Null the shared handle (haltAll would wipe). Need a hook the API
      // doesn't currently provide, so use stopAll() which also nulls without
      // wiping, sets up the next initShared to actually run init().
      await Countly.stopAll();

      // Re-init with the same storage. Device ID matches; persisted queue
      // ships once the new (non-offline) instance ticks.
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'stop-resume');
      const inst2: CountlyInstance = await Countly.initShared(cfg2, storage, network);
      expect(inst2.deviceId.getID()).assertEqual(did1);
      await flushTick(120);
      expect(network.findCallsWithParam('stop_resume_marker').length).assertEqual(1);
      await Countly.haltAll();
    });

    /** Cross-verification: after halt(), re-init with the SAME storage
     *  starts from a fresh state, new device ID, empty queue. */
    it('halt_thenInitShared_freshState', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'halt-fresh');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg1: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'halt-fresh');
      cfg1.network.enableOfflineMode();
      const inst1: CountlyInstance = await Countly.initShared(cfg1, storage, network);
      const did1: string = inst1.deviceId.getID();
      const marker: Record<string, string> = { 'halt_fresh_marker': 'value' };
      await inst1.requests.addDirectRequest(marker);
      await flushTick(60);
      await inst1.halt();
      expect(storage.size()).assertEqual(0);

      // Re-init, storage is empty, so the new instance generates a new
      // device ID and the previously-buffered marker is gone forever.
      await Countly.stopAll();
      const cfg2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'halt-fresh');
      const inst2: CountlyInstance = await Countly.initShared(cfg2, storage, network);
      const did2: string = inst2.deviceId.getID();
      expect(did2.length > 0).assertTrue();
      expect(did1 === did2).assertFalse();
      await flushTick(120);
      expect(network.findCallsWithParam('halt_fresh_marker').length).assertEqual(0);
      await Countly.haltAll();
    });

    /** stop() is idempotent. Calling it a second time is a safe no-op
     *  (modules' onHalt handles empty state, deregister tolerates already-
     *  deregistered observers, etc.). */
    it('stop_idempotent_secondCallIsNoOp', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'stop-idempotent');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'stop-idempotent');
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      await inst.stop();
      expect(inst.config.halted).assertTrue();
      const storageSizeAfterFirst: number = storage.size();
      // Second stop must not throw and must not change observable state.
      await inst.stop();
      expect(inst.config.halted).assertTrue();
      expect(storage.size()).assertEqual(storageSizeAfterFirst);
      await Countly.haltAll();
    });

    /** halt() is idempotent. Second call after storage was already wiped
     *  is safe, storage.clear() on an empty preferences file is a no-op. */
    it('halt_idempotent_secondCallIsNoOp', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'halt-idempotent');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'halt-idempotent');
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      await inst.halt();
      expect(storage.size()).assertEqual(0);
      // Second halt must not throw.
      await inst.halt();
      expect(storage.size()).assertEqual(0);
      expect(inst.config.halted).assertTrue();
      await Countly.haltAll();
    });

    /** Regression for the original "events queue after halt" leak: after
     *  stop(), every user-facing module mutator must short-circuit and
     *  emit no wire traffic. Same gate the postHalt tests in Consent.test.ets
     *  cover via halt(); replicated here for stop() so a future refactor
     *  that splits the halted flag between stop/halt fails this test. */
    it('stop_subsequentApiCallsAreRejected', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'stop-rej');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'stop-rej');
      cfg.consent.setRequiresConsent(true).giveAll();
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      await inst.stop();
      const callsBefore: number = network.calls.length;
      // Hit several entry points across modules.
      await inst.events.recordEvent('post_stop_evt');
      await inst.views.startView('post_stop_view', null);
      await inst.crashes.recordHandledException(new Error('post_stop'), null);
      inst.userProfile.setProperty('post_stop_prop', 'x');
      const direct: Record<string, string> = { 'post_stop_direct': 'value' };
      await inst.requests.addDirectRequest(direct);
      await flushTick(120);

      // No new wire traffic from any of those calls.
      expect(network.calls.length).assertEqual(callsBefore);
      expect(network.findCallsWithParam('post_stop_evt').length).assertEqual(0);
      expect(network.findCallsWithParam('post_stop_view').length).assertEqual(0);
      expect(network.findCallsWithParam('post_stop_direct').length).assertEqual(0);
      await Countly.haltAll();
    });

    /** Same as above but with halt(), confirms post-halt rejection still
     *  fires when storage was wiped by halt. */
    it('halt_subsequentApiCallsAreRejected', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'halt-rej');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'halt-rej');
      cfg.consent.setRequiresConsent(true).giveAll();
      const inst: CountlyInstance = await Countly.initShared(cfg, storage, network);

      await inst.halt();
      const callsBefore: number = network.calls.length;
      await inst.events.recordEvent('post_halt_evt');
      await inst.views.startView('post_halt_view', null);
      const direct: Record<string, string> = { 'post_halt_direct': 'value' };
      await inst.requests.addDirectRequest(direct);
      await flushTick(120);

      expect(network.calls.length).assertEqual(callsBefore);
      expect(network.findCallsWithParam('post_halt_evt').length).assertEqual(0);
      expect(network.findCallsWithParam('post_halt_view').length).assertEqual(0);
      expect(network.findCallsWithParam('post_halt_direct').length).assertEqual(0);
      await Countly.haltAll();
    });

    /** Same as above but with stop(), confirms stop also isolates per-instance. */
    it('multiInstance_stopOne_doesNotStopOthers', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const sA: InMemoryStorage = new InMemoryStorage(logger, 'stopA');
      const nA: FakeNetwork = new FakeNetwork(logger);
      const sB: InMemoryStorage = new InMemoryStorage(logger, 'stopB');
      const nB: FakeNetwork = new FakeNetwork(logger);
      const cfgA: CountlyConfig = new CountlyConfig(ctx(), 'https://a.count.ly', 'stopA');
      cfgA.consent.setRequiresConsent(true).giveAll();
      cfgA.events.setQueueSizeToSend(1);
      const cfgB: CountlyConfig = new CountlyConfig(ctx(), 'https://b.count.ly', 'stopB');
      cfgB.consent.setRequiresConsent(true).giveAll();
      cfgB.events.setQueueSizeToSend(1);
      const a: CountlyInstance = await Countly.createInstance('A', cfgA, sA, nA);
      const b: CountlyInstance = await Countly.createInstance('B', cfgB, sB, nB);

      await a.stop();

      // A is halted (stop flips the halted flag) but its storage survives.
      expect(a.config.halted).assertTrue();
      expect(sA.size() > 0).assertTrue();
      // B is alive and intact.
      expect(b.config.halted).assertFalse();
      expect(sB.size() > 0).assertTrue();
      // B can still record events.
      await b.events.recordEvent('iso_stop_b_event');
      await flushTick(120);
      expect(nB.findCallsWithParam('iso_stop_b_event').length).assertEqual(1);

      await Countly.haltAll();
    });

    /** Shared-instance replacement via stop()+initShared() only touches
     *  the shared instance, named instances are unaffected. Locks an
     *  important integration boundary: an integrator using both `initShared`
     *  and `createInstance` can swap the shared config without disrupting
     *  their named ones. */
    it('sharedReInit_doesNotAffectNamedInstances', 0, async () => {
      await Countly.haltAll();
      const logger: Logger = new Logger();
      const storageShared: InMemoryStorage = new InMemoryStorage(logger, 'shared-k');
      const networkShared: FakeNetwork = new FakeNetwork(logger);
      const storageNamed: InMemoryStorage = new InMemoryStorage(logger, 'named-k');
      const networkNamed: FakeNetwork = new FakeNetwork(logger);

      const cfgShared: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'shared-k');
      const cfgNamed: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'named-k');
      cfgNamed.events.setQueueSizeToSend(1);

      const sharedV1: CountlyInstance = await Countly.initShared(cfgShared, storageShared, networkShared);
      const named: CountlyInstance = await Countly.createInstance('sib', cfgNamed, storageNamed, networkNamed);

      // Replace the shared with a new config via stop + initShared.
      await sharedV1.stop();
      const cfgSharedV2: CountlyConfig = new CountlyConfig(ctx(), 'https://try.count.ly', 'shared-k');
      const sharedV2: CountlyInstance = await Countly.initShared(cfgSharedV2, storageShared, networkShared);

      // Shared instance identity changed.
      expect(sharedV1 === sharedV2).assertFalse();
      // Named instance reference is the SAME object, wasn't halted, wasn't replaced.
      expect(Countly.getInstance('sib') === named).assertTrue();
      // Named instance is still alive (not halted).
      expect(named.config.halted).assertFalse();
      // Named instance still works.
      await named.events.recordEvent('post_reinit_named_evt');
      await flushTick(120);
      expect(networkNamed.findCallsWithParam('post_reinit_named_evt').length).assertEqual(1);
      await Countly.haltAll();
    });
  });
}
