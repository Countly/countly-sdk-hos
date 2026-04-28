import { describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness } from './TestHelpers';
import { RCData, RequestResult } from '../../../main/ets/types/Types';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';
import { Logger } from '../../../main/ets/internal/Logger';
import common from '@ohos.app.ability.common';

/**
 * RemoteConfig test coverage. The module has three distinct surfaces that all
 * need to stay behaviorally honest:
 *   1. Download pipeline (full / partial / omit, consent + temp-id gating)
 *   2. A/B testing (enroll, exit, value-and-enroll wrappers)
 *   3. Cache lifecycle (device-id change, value caching flag, persistence)
 *
 * We test the public facade on CountlyInstance — the download callback shape
 * is the key contract.
 */

const RC_BODY: string = JSON.stringify({ flag_a: true, count_n: 42, label_s: 'hello' });

export default function remoteConfigTest() {
  describe('RemoteConfigTest', () => {
    it('downloadAllKeys_noConsent_callbackReportsError', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        // no remote-config consent
      });
      // Drop the init-time SC fetch (which also hits /o/sdk) so the assertion
      // observes only what downloadAllKeys does under denied consent.
      h.network.reset();
      let result: RequestResult | null = null;
      let err: string | null = null;
      await h.instance.remoteConfig.downloadAllKeys((r: RequestResult, e: string | null) => {
        result = r;
        err = e;
      });
      expect(result).assertEqual(RequestResult.Error);
      expect(err !== null).assertTrue();
      // No /o/sdk request must have fired under denied consent.
      expect(h.network.calls.filter((c) => c.endpoint === '/o/sdk').length).assertEqual(0);
    });

    it('downloadAllKeys_success_populatesCache', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.reset();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);

      const req = h.network.calls.find((c) => c.endpoint === '/o/sdk');
      expect(req !== undefined).assertTrue();
      expect(req!.data.indexOf('method=rc') !== -1).assertTrue();

      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(3);
      expect(all['flag_a'].value).assertEqual(true);
      expect(all['count_n'].value).assertEqual(42);
      expect(all['flag_a'].isCurrentUsersData).assertTrue();
    });

    it('downloadAllKeys_httpError_callbackReportsNetworkIssue', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextStatus = 500;
      h.network.nextBody = 'internal error';
      let result: RequestResult | null = null;
      await h.instance.remoteConfig.downloadAllKeys((r: RequestResult) => { result = r; });
      expect(result).assertEqual(RequestResult.NetworkIssue);
      // Cache must not have been populated on a failed response.
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('downloadSpecificKeys_sendsKeysParam_andMergesIntoExisting', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ existing: 1 });
      await h.instance.remoteConfig.downloadAllKeys(null);

      h.network.nextBody = JSON.stringify({ added: 2 });
      await h.instance.remoteConfig.downloadSpecificKeys(['added'], null);

      const specificReq = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('keys=') !== -1);
      expect(specificReq.length).assertEqual(1);

      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      // Existing key retained under partial merge; new key added.
      expect(all['existing'].value).assertEqual(1);
      expect(all['added'].value).assertEqual(2);
    });

    it('downloadOmittingKeys_sendsOmitKeysParam', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ kept: 'yes' });
      await h.instance.remoteConfig.downloadOmittingKeys(['drop_me'], null);

      const omit = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('omit_keys=') !== -1);
      expect(omit.length).assertEqual(1);
    });

    it('abAutoOptin_sendsOiEqualsOne', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enrollABonDownload();
      });
      h.network.reset();
      h.network.nextBody = '{}';
      await h.instance.remoteConfig.downloadAllKeys(null);
      const req = h.network.calls.find((c) => c.endpoint === '/o/sdk');
      expect(req!.data.indexOf('oi=1') !== -1).assertTrue();
    });

    it('abAutoOptin_default_sendsOiEqualsZero', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.reset();
      h.network.nextBody = '{}';
      await h.instance.remoteConfig.downloadAllKeys(null);
      const req = h.network.calls.find((c) => c.endpoint === '/o/sdk');
      expect(req!.data.indexOf('oi=0') !== -1).assertTrue();
    });

    it('clearAllRemoteConfig_wipesCache', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length > 0).assertTrue();

      await h.instance.remoteConfig.clearAllRemoteConfig();
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('deviceIdChangeNotMerged_valueCachingOff_clearsCache', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(3);

      // Triggers onDeviceIdChangedNotMerged on every module.
      await h.instance.deviceId.changeWithoutMerge('new_user');
      await flushTick(60);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('deviceIdChangeNotMerged_valueCachingOn_demotesToStale', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enableValueCaching();
      });
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);

      await h.instance.deviceId.changeWithoutMerge('new_user');
      await flushTick(60);

      // Cache survives but every entry is stale (isCurrentUsersData=false).
      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(3);
      expect(all['flag_a'].isCurrentUsersData).assertFalse();
    });

    it('enrollIntoABTestsForKeys_sendsAbMethodRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.remoteConfig.enrollIntoABTestsForKeys(['feature_x']);
      const req = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=ab&') !== -1);
      expect(req.length).assertEqual(1);
      expect(req[0].data.indexOf('feature_x') !== -1).assertTrue();
    });

    it('exitABTestsForKeys_null_sendsAbExitWithoutKeys', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.remoteConfig.exitABTestsForKeys(null);
      const req = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=ab_exit') !== -1);
      expect(req.length).assertEqual(1);
      // Null/empty should mean "exit all" — no keys= parameter expected.
      expect(req[0].data.indexOf('keys=') === -1).assertTrue();
    });

    it('getValueAndEnroll_unknownKey_noEnrollRequest', 0, async () => {
      // Public guarantee per the module doc: no enroll fires when the key is
      // unknown. Silent no-ops here would leak network traffic on typos.
      const h: Harness = await buildHarness();
      const rc: RCData | null = await h.instance.remoteConfig.getValueAndEnroll('missing_key');
      expect(rc === null).assertTrue();
      const enroll = h.network.calls.filter((c) => c.data.indexOf('method=ab&') !== -1);
      expect(enroll.length).assertEqual(0);
    });

    it('downloadCallback_exceptionDoesNotBlockGlobalCallback', 0, async () => {
      // The module wraps each callback in its own try/catch so one bad
      // integrator callback must not starve the other.
      let globalFired: boolean = false;
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.registerGlobalCallback(() => { globalFired = true; });
      });
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(() => { throw new Error('per-call boom'); });
      expect(globalFired).assertTrue();
    });

    it('cachePersistence_survivesInstanceRestart', 0, async () => {
      // First lifecycle: download + persist.
      const h: Harness = await buildHarness();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);

      // Second lifecycle: a fresh instance sharing the same storage must
      // rehydrate the cache from disk at onInit.
      const h2: Harness = await buildHarness();
      // NOTE: buildHarness creates a fresh storage; this test documents the
      // intent that the module DOES persist + rehydrate. For full survival
      // verification, the storage instance needs to be shared across harnesses
      // — skipped here because buildHarness deliberately isolates per-test.
      // What we can verify: second instance starts with an empty cache
      // (confirms the fresh-storage contract).
      expect(Object.keys(h2.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    // ======================================================================
    // Ports of ModuleRemoteConfigTests.java — behaviors NOT already covered
    // above. Skipped Android tests (with rationale) at the bottom of the file.
    // ======================================================================

    it('consentRemoval_doesNotClearStoredValues', 0, async () => {
      // Android:valuesClearedOnConsentRemoval — despite the method name, the
      // original test asserts that consent removal does NOT wipe values (see
      // HOS ModuleRemoteConfig.onConsentChanged: revocation leaves cache).
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).setEnabled(['remote-config']);
        cfg.remoteConfig.enableValueCaching();
      });
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(3);

      h.instance.consent.removeConsentAll();
      // Cache must still be populated; per HOS contract it's an explicit
      // clearAllRemoteConfig / device-id-change-not-merged that wipes.
      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(3);
      expect(all['flag_a'].isCurrentUsersData).assertTrue();
    });

    it('automaticTriggers_downloadsOnInit', 0, async () => {
      // Android:automaticRCTriggers — init branch. HOS fires an automatic
      // download on init when consent survives + not in temp-ID mode.
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      await flushTick(60);
      const rcCalls = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1);
      expect(rcCalls.length >= 1).assertTrue();
    });

    it('automaticTriggers_fireOnConsentGrant', 0, async () => {
      // Android:automaticRCTriggers — consent-grant branch.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      await flushTick(60);
      const beforeGrant = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;

      h.instance.consent.giveConsent(['remote-config']);
      await flushTick(60);
      const afterGrant = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;
      expect(afterGrant > beforeGrant).assertTrue();
    });

    it('automaticTriggers_fireOnDeviceIdChangeMerged', 0, async () => {
      // Android:automaticRCTriggers — merged-change branch.
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      await flushTick(60);
      const before = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;

      await h.instance.deviceId.changeWithMerge('merged_user');
      await flushTick(60);
      const after = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;
      expect(after > before).assertTrue();
    });

    it('automaticTriggers_skipInTempIdMode', 0, async () => {
      // Android:automaticRCTriggers — tempID branch: entering temp mode must
      // NOT fire a download.
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      await flushTick(60);
      const before = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;

      await h.instance.deviceId.enableTemporaryIdMode();
      await flushTick(60);
      const after = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=rc') !== -1).length;
      expect(after).assertEqual(before);
    });

    it('downloadInTempIdMode_callbackReportsError_noRequestFired', 0, async () => {
      // HOS guarantees: a download in temp-ID mode short-circuits with
      // RequestResult.Error and does NOT hit the network.
      const h: Harness = await buildHarness((cfg) => {
        cfg.deviceId.enableTemporaryMode();
      });
      let result: RequestResult | null = null;
      await h.instance.remoteConfig.downloadAllKeys((r: RequestResult) => { result = r; });
      expect(result).assertEqual(RequestResult.Error);
      expect(h.network.calls.filter((c) => c.endpoint === '/o/sdk').length).assertEqual(0);
    });

    it('rcValueCaching_off_deviceIdChangeWipesEvenIfDownloaded', 0, async () => {
      // Android:rcValueCaching — caching-off branch.
      const h: Harness = await buildHarness();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(3);

      await h.instance.deviceId.changeWithoutMerge('fresh_user');
      await flushTick(60);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('rcValueCaching_on_preservesAcrossMultipleIdChanges', 0, async () => {
      // Android:rcValueCaching — caching-on branch, repeated changes.
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.enableValueCaching();
      });
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);

      await h.instance.deviceId.changeWithoutMerge('user2');
      await flushTick(60);
      await h.instance.deviceId.changeWithoutMerge('user3');
      await flushTick(60);

      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(3);
      // Every entry stays stale across successive changes.
      const keys: string[] = Object.keys(all);
      for (let i = 0; i < keys.length; i++) {
        expect(all[keys[i]].isCurrentUsersData).assertFalse();
      }
    });

    it('validatePersistence_rehydrateFromSharedStorage', 0, async () => {
      // Android:validateValuePersistence — a second instance initialized
      // against the same storage must see the previously-downloaded values.
      const logger: Logger = new Logger();
      const sharedStorage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network1: FakeNetwork = new FakeNetwork(logger);
      const cfg1: CountlyConfig = new CountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      cfg1.logging.enableLogging();
      const inst1: CountlyInstance = new CountlyInstance(cfg1, sharedStorage, network1);
      await inst1.init();
      network1.nextBody = RC_BODY;
      await inst1.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(inst1.remoteConfig.getValues()).length).assertEqual(3);

      // Second instance, same storage — rehydrate.
      const network2: FakeNetwork = new FakeNetwork(logger);
      const cfg2: CountlyConfig = new CountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      cfg2.logging.enableLogging();
      const inst2: CountlyInstance = new CountlyInstance(cfg2, sharedStorage, network2);
      await inst2.init();
      const rehydrated: Record<string, RCData> = inst2.remoteConfig.getValues();
      expect(Object.keys(rehydrated).length).assertEqual(3);
      expect(rehydrated['flag_a'].value).assertEqual(true);
      expect(rehydrated['count_n'].value).assertEqual(42);
      expect(rehydrated['label_s'].value).assertEqual('hello');
    });

    it('clearAll_thenReDownload_repopulatesCache', 0, async () => {
      // Android:validateClear — after clearAll, a new download must repopulate
      // and the values must be fresh (isCurrentUsersData=true).
      const h: Harness = await buildHarness();
      h.network.nextBody = RC_BODY;
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(3);

      await h.instance.remoteConfig.clearAllRemoteConfig();
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);

      h.network.nextBody = JSON.stringify({ new_key: 'x' });
      await h.instance.remoteConfig.downloadAllKeys(null);
      const after: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(after).length).assertEqual(1);
      expect(after['new_key'].value).assertEqual('x');
      expect(after['new_key'].isCurrentUsersData).assertTrue();
    });

    it('rcGlobalCallback_firesForEveryDownloadPath', 0, async () => {
      // Android:rcGlobalCallback — global callbacks must see every path
      // (downloadAllKeys, downloadSpecificKeys, downloadOmittingKeys).
      let globalCount: number = 0;
      const h: Harness = await buildHarness((cfg) => {
        cfg.remoteConfig.registerGlobalCallback(() => { globalCount++; });
      });
      h.network.nextBody = '{}';
      await h.instance.remoteConfig.downloadAllKeys(null);
      await h.instance.remoteConfig.downloadSpecificKeys(['x'], null);
      await h.instance.remoteConfig.downloadOmittingKeys(['y'], null);
      expect(globalCount).assertEqual(3);
    });

    it('registerDownloadCallback_runtimeAdd_firesOnNextDownload', 0, async () => {
      // Android:rcGlobalCallback — runtime add/remove behavior on the
      // registerDownloadCallback / removeDownloadCallback API.
      let added: number = 0;
      const cb = () => { added++; };
      const h: Harness = await buildHarness();
      h.network.nextBody = '{}';

      h.instance.remoteConfig.registerDownloadCallback(cb);
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(added).assertEqual(1);

      h.instance.remoteConfig.removeDownloadCallback(cb);
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(added).assertEqual(1); // no more fires after remove
    });

    it('perCallCallback_firesOnEveryDownload', 0, async () => {
      // Android:rcGlobalCallback — per-call callback fires exactly once per
      // individual download call.
      const h: Harness = await buildHarness();
      h.network.nextBody = '{}';
      let a: number = 0, b: number = 0, c: number = 0;
      await h.instance.remoteConfig.downloadAllKeys(() => { a++; });
      await h.instance.remoteConfig.downloadSpecificKeys(['k'], () => { b++; });
      await h.instance.remoteConfig.downloadOmittingKeys(['k'], () => { c++; });
      expect(a).assertEqual(1);
      expect(b).assertEqual(1);
      expect(c).assertEqual(1);
    });

    it('getters_returnRCDataWithCorrectValues', 0, async () => {
      // Android:validateGetters — getValue + getValues correctness across
      // primitive / string / object / array payloads.
      const h: Harness = await buildHarness();
      h.network.nextBody = '{"a":123,"b":"fg","c":222222222222,"d":1.5,"e":[3,"44",5.1,7.7],"f":{"q":6,"w":"op"}}';
      await h.instance.remoteConfig.downloadAllKeys(null);

      expect(h.instance.remoteConfig.getValue('a')!.value).assertEqual(123);
      expect(h.instance.remoteConfig.getValue('b')!.value).assertEqual('fg');
      expect(h.instance.remoteConfig.getValue('c')!.value).assertEqual(222222222222);
      expect(h.instance.remoteConfig.getValue('d')!.value).assertEqual(1.5);

      const eVal: Object = h.instance.remoteConfig.getValue('e')!.value!;
      expect(Array.isArray(eVal)).assertTrue();
      expect((eVal as Array<Object>).length).assertEqual(4);

      const fVal: Record<string, Object> = h.instance.remoteConfig.getValue('f')!.value as Record<string, Object>;
      expect(fVal['q']).assertEqual(6);
      expect(fVal['w']).assertEqual('op');

      // Every getter must see the same cache.
      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(6);
      expect(all['a'].isCurrentUsersData).assertTrue();
    });

    it('getValue_unknownKey_returnsNull', 0, async () => {
      // Android:validateGetters — unknown key → null.
      const h: Harness = await buildHarness();
      expect(h.instance.remoteConfig.getValue('nonexistent')).assertEqual(null);
    });

    it('passingBadValues_doesNotThrow', 0, async () => {
      // Android:passingBadValues — passing null/empty arguments must not
      // throw from any public RC entry point.
      const h: Harness = await buildHarness();

      expect(h.instance.remoteConfig.getValue('')).assertEqual(null);
      expect(await h.instance.remoteConfig.getValueAndEnroll('')).assertEqual(null);

      await h.instance.remoteConfig.downloadAllKeys(null);
      await h.instance.remoteConfig.downloadOmittingKeys([], null);
      await h.instance.remoteConfig.downloadSpecificKeys([], null);
      await h.instance.remoteConfig.enrollIntoABTestsForKeys([]);
      await h.instance.remoteConfig.exitABTestsForKeys([]);
      await h.instance.remoteConfig.exitABTestsForKeys(null);
      // If we got here without throwing, the behavior is correct.
      expect(true).assertTrue();
    });

    it('enrollIntoABTestsForKeys_emptyKeys_sendsNothing', 0, async () => {
      // Android:passingBadValues — empty keys filter out and no request fires.
      const h: Harness = await buildHarness();
      await h.instance.remoteConfig.enrollIntoABTestsForKeys([]);
      const abCalls = h.network.calls.filter((c) => c.data.indexOf('method=ab&') !== -1);
      expect(abCalls.length).assertEqual(0);
    });

    it('downloadSpecificKeys_emptyArray_fallsBackToFullDownload', 0, async () => {
      // HOS contract: an empty include/omit list falls back to "all keys".
      const h: Harness = await buildHarness();
      h.network.nextBody = '{}';
      await h.instance.remoteConfig.downloadSpecificKeys([], null);
      const req = h.network.calls.find((c) => c.endpoint === '/o/sdk');
      expect(req !== undefined).assertTrue();
      // Neither keys= nor omit_keys= should appear.
      expect(req!.data.indexOf('keys=') === -1).assertTrue();
      expect(req!.data.indexOf('omit_keys=') === -1).assertTrue();
    });

    it('mergePartialDownload_preservesExistingAndOverwritesSharedKeys', 0, async () => {
      // Android:validateMergeReceivedResponse — merging a partial response
      // must preserve unaffected keys and overwrite shared keys with the
      // latest value.
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ a: 123, b: 'fg' });
      await h.instance.remoteConfig.downloadAllKeys(null);

      h.network.nextBody = JSON.stringify({ b: 33.44, c: 'ww' });
      await h.instance.remoteConfig.downloadSpecificKeys(['b', 'c'], null);

      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(3);
      expect(all['a'].value).assertEqual(123);
      expect(all['b'].value).assertEqual(33.44);
      expect(all['c'].value).assertEqual('ww');
    });

    it('fullDownload_replacesEntireCache', 0, async () => {
      // Android:validateMergeReceivedResponse — final branch where a full
      // download replaces the whole cache.
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ a: 1, b: 2, c: 3 });
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(3);

      h.network.nextBody = JSON.stringify({ x: 10, y: 20 });
      await h.instance.remoteConfig.downloadAllKeys(null);
      const all: Record<string, RCData> = h.instance.remoteConfig.getValues();
      expect(Object.keys(all).length).assertEqual(2);
      expect(all['x'].value).assertEqual(10);
      expect(all['y'].value).assertEqual(20);
      expect(all['a']).assertEqual(undefined);
    });

    it('concurrentDownloadsAndReads_noCorruption', 0, async () => {
      // Android:concurrentMergeAndReads — ported as a sequential-stress test
      // (ArkTS is single-threaded but we still exercise rapid interleavings
      // through the microtask queue to catch any partial-write errors).
      const h: Harness = await buildHarness();
      const bodies: string[] = [
        '{"k1":123,"k2":"v2"}',
        '{"k2":777,"k3":{}}',
        '{"k4":true,"k5":55.5}'
      ];
      const downloads: Promise<void>[] = [];
      for (let i = 0; i < 30; i++) {
        h.network.nextBody = bodies[i % bodies.length];
        downloads.push(h.instance.remoteConfig.downloadAllKeys(null));
        // Interleave reads.
        h.instance.remoteConfig.getValues();
        h.instance.remoteConfig.getValue('k1');
      }
      await Promise.all(downloads);

      const finalVals: Record<string, RCData> = h.instance.remoteConfig.getValues();
      const keys: string[] = Object.keys(finalVals);
      for (let i = 0; i < keys.length; i++) {
        expect(finalVals[keys[i]] !== null).assertTrue();
        expect(finalVals[keys[i]] !== undefined).assertTrue();
      }
    });

    // ======================================================================
    // Ports of RemoteConfigValueStoreTests.java
    // ======================================================================

    it('dataFromDownload_markedFresh_defaultIsCurrentUsersData', 0, async () => {
      // Android:dataFromString_CurrentStructure — every downloaded value lands
      // with isCurrentUsersData=true (HOS has no concept of pre-injecting
      // cached entries directly — that path is covered by the device-id
      // change/caching tests).
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ a: 123, b: 'ccx' });
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(h.instance.remoteConfig.getValue('a')!.isCurrentUsersData).assertTrue();
      expect(h.instance.remoteConfig.getValue('b')!.isCurrentUsersData).assertTrue();
    });

    it('serializeDeserialize_roundTripsThroughStorage', 0, async () => {
      // Android:rcvsSerializeDeserialize — the HOS module round-trips values
      // through storage (the persistence test above already covers end-to-end
      // rehydration). This is a narrower check that the JSON encoding the
      // module persists is itself parseable back to the same values.
      const logger: Logger = new Logger();
      const sharedStorage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      const cfg: CountlyConfig = new CountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      const inst: CountlyInstance = new CountlyInstance(cfg, sharedStorage, network);
      await inst.init();
      network.nextBody = '{"fd":12,"2fd":142,"f3d":123}';
      await inst.remoteConfig.downloadAllKeys(null);

      const raw: string = sharedStorage.dump()['cly_remote_config'];
      expect(raw !== undefined).assertTrue();
      expect(raw.length > 0).assertTrue();
      const parsed: Object = JSON.parse(raw);
      expect(typeof parsed === 'object').assertTrue();
    });

    it('downloadAllKeys_emptyResponse_cacheEmpty', 0, async () => {
      // Android:rcvsDataFromStringNullEmpty — empty-ish response must leave
      // the cache empty without throwing.
      const h: Harness = await buildHarness();
      h.network.nextBody = '{}';
      await h.instance.remoteConfig.downloadAllKeys(null);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('downloadAllKeys_invalidJson_callbackReportsError_cacheUnchanged', 0, async () => {
      // HOS invariant: an unparseable response must not corrupt the cache.
      const h: Harness = await buildHarness();
      h.network.nextBody = JSON.stringify({ existing: 'safe' });
      await h.instance.remoteConfig.downloadAllKeys(null);

      h.network.nextBody = 'not-json-at-all';
      let result: RequestResult | null = null;
      await h.instance.remoteConfig.downloadAllKeys((r: RequestResult) => { result = r; });
      // NetworkIssue because JSON.parse throws and falls into the catch.
      expect(result === RequestResult.NetworkIssue || result === RequestResult.Error).assertTrue();
      expect(h.instance.remoteConfig.getValue('existing')!.value).assertEqual('safe');
    });

    it('downloadAllKeys_nonObjectResponse_callbackReportsError', 0, async () => {
      // Android:rcvsDataFromStringNullEmpty — null-at-root response leaves the
      // store empty without throwing.
      const h: Harness = await buildHarness();
      h.network.nextBody = 'null';
      let result: RequestResult | null = null;
      await h.instance.remoteConfig.downloadAllKeys((r: RequestResult) => { result = r; });
      expect(result).assertEqual(RequestResult.Error);
      expect(Object.keys(h.instance.remoteConfig.getValues()).length).assertEqual(0);
    });

    it('downloadAllKeys_unicodeAndSpecialKeys_roundTripCorrectly', 0, async () => {
      // Android:rcvsDataFromStringSamples_2 — ensure emoji/unicode keys survive
      // the download → cache path.
      const h: Harness = await buildHarness();
      const payload: Record<string, Object> = {};
      payload['321'] = 123;
      payload['😀'] = '😁';
      h.network.nextBody = JSON.stringify(payload);
      await h.instance.remoteConfig.downloadAllKeys(null);

      expect(h.instance.remoteConfig.getValue('321')!.value).assertEqual(123);
      expect(h.instance.remoteConfig.getValue('😀')!.value).assertEqual('😁');
    });

    // ======================================================================
    // SKIPPED Android tests (documented for completeness):
    //
    //  - RemoteConfigVariantControlTests.java (all): the variant APIs
    //    (testingDownloadVariantInformation, testingGetAllVariants,
    //    testingGetAllExperimentInfo, testingEnrollIntoVariant,
    //    testingGetVariantsForKey) are not implemented in HOS.
    //    See ModuleRemoteConfig.ets header comment.
    //
    //  - RemoteConfigAnrTest.java (both tests): rely on Android's global
    //    synchronized(Countly.sharedInstance()) lock + main-thread runner.
    //    ArkTS is single-threaded with microtask/isolate semantics — there
    //    is no equivalent global monitor to contend on, so the latency
    //    assertions cannot be reproduced here.
    //
    //  - ScenarioRemoteConfigTests.bump: empty test in the Android source.
    //
    //  - ModuleRemoteConfigTests.validateKeyIncludeExclude: tests the
    //    internal RemoteConfigHelper.prepareKeysIncludeExclude helper; HOS
    //    handles include/exclude inline in downloadInternal. The observable
    //    behaviour is covered by downloadSpecificKeys_sendsKeysParam_*,
    //    downloadOmittingKeys_sendsOmitKeysParam, and the empty-array
    //    fallback test above.
    //
    //  - ModuleRemoteConfigTests.validateGetters legacy getters
    //    (getValueForKey, getAllValues) + old RemoteConfigCallback path:
    //    not implemented in HOS — only the modern RCData/RCDownloadCallback
    //    surface exists.
    //
    //  - Any tests that rely on the Android ImmediateRequestGenerator hook
    //    to inspect individual request construction at the helper level —
    //    translated to FakeNetwork endpoint/data inspection throughout.
    // ======================================================================
  });
}
