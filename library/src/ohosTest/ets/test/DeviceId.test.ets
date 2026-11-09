import { afterEach, describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { DeviceIdType, LogLevel } from '../../../main/ets/types/Types';
import { TEMP_DEVICE_ID } from '../../../main/ets/internal/RequestQueue';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { FakeNetwork, RecordedCall } from './doubles/FakeNetwork';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { Logger } from '../../../main/ets/internal/Logger';

/** In-memory storage whose reads and writes take a moment, as the platform preferences do. */
class SlowStorage extends InMemoryStorage {
  constructor(logger: Logger, appKey: string) {
    super(logger, appKey);
  }

  /** Reads the value after a short wait. */
  public override async getString(key: string, fallback: string): Promise<string> {
    await flushTick(5);
    return super.getString(key, fallback);
  }

  /** Writes the value after a short wait. */
  public override async setString(key: string, value: string): Promise<boolean> {
    await flushTick(5);
    return super.setString(key, value);
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

export default function deviceIdTest() {
  describe('DeviceIdTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('firstInit_generatesUuid', 0, async () => {
      const h: Harness = await buildHarness();
      expect(h.instance.deviceId.getID().length > 0).assertTrue();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    it('firstInit_customIdIsUsed', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('customUser1'); });
      expect(h.instance.deviceId.getID()).assertEqual('customUser1');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    it('temporaryIdMode_usesPlaceholder', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(h.instance.deviceId.getID()).assertEqual('CLYTemporaryDeviceID');
    });

    it('setID_fromSdkGenerated_mergesOnServer', 0, async () => {
      const h: Harness = await buildHarness();
      const oldId: string = h.instance.deviceId.getID();
      await h.instance.deviceId.setID('newId');
      await flushTick(60);
      // Expect a request with old_device_id
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(1);
      expect(h.instance.deviceId.getID()).assertEqual('newId');
    });

    it('setID_fromDeveloperSupplied_doesNotMerge', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('userA'); });
      await h.instance.deviceId.setID('userB');
      await flushTick(60);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.instance.deviceId.getID()).assertEqual('userB');
    });

    it('setID_sameId_ignored', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('same'); });
      await h.instance.deviceId.setID('same');
      await flushTick(60);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
    });

    it('enableOfflineMode_switchesAtRuntime', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.enableOfflineMode();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
    });

    it('changeWithMerge_sendsMergeRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.changeWithMerge('merged_id');
      await flushTick(60);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(1);
    });

    it('changeWithoutMerge_replacesWithoutMergeRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.changeWithoutMerge('fresh');
      await flushTick(60);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.instance.deviceId.getID()).assertEqual('fresh');
    });

    it('changeWithoutMerge_clearsConsentAndTimedEvents', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      // Start a timed event, then swap user without merge.
      h.instance.events.startEvent('checkout');
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      await h.instance.deviceId.changeWithoutMerge('newUser');
      await flushTick(100);
      // All consents should have been cleared as part of the not-merged flow.
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
      expect(h.instance.consentModule.hasConsent('crashes')).assertFalse();
      // Timed events should have been cleared, so endEvent on the previous
      // key is a no-op (no events request produced).
      await h.instance.events.endEvent('checkout');
      await flushTick(60);
      // Match on `events=` (the URL-encoded query param), NOT bare `events`,
      // which would also match the init-time consent snapshot whose JSON body
      // contains the feature name `"events":true` URL-encoded as %22events%22.
      // The init-time consent flush legitimately ships before this assertion.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
    });

    it('changeWithoutMerge_emitsEndSessionUnderOldId_resumesOnForeground', 0, async () => {
      // Mirror Android sdk/ModuleDeviceId.changeDeviceIdWithoutMergeInternal:140
      // and scenario 20 step 4 of SDK_REQUEST_SCENARIOS.md: in non-manual mode
      // a changeWithoutMerge during an active session emits a closing
      // end_session=1 under the OLD device_id before the swap. The new
      // session only begins on the next foreground cycle.
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      const oldId: string = h.instance.deviceId.getID();
      await h.instance.deviceId.changeWithoutMerge('nextUser');
      await flushTick(120);
      const endCalls = h.network.findCallsWithParam('end_session=1');
      expect(endCalls.length).assertEqual(1);
      // The closing end_session must carry the OLD device_id.
      expect(endCalls[0].data.indexOf(`device_id=${oldId}`) !== -1).assertTrue();
      // No automatic begin yet, fresh session waits for the next foreground.
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      // Background → foreground cycles the session under the new id.
      h.instance.lifecycleBackground();
      await flushTick(60);
      h.instance.lifecycleForeground();
      await flushTick(60);
      const beginCalls = h.network.findCallsWithParam('begin_session=1');
      expect(beginCalls.length).assertEqual(2);
      expect(beginCalls[1].data.indexOf('device_id=nextUser') !== -1).assertTrue();
    });

    it('changeWithoutMerge_manualMode_skipsEndSession', 0, async () => {
      // Mirror Android sdk/ModuleDeviceId.changeDeviceIdWithoutMergeInternal:138
      // and scenario 20 step 4 ("Skipped in manual session mode"): in manual
      // session mode the SDK does NOT emit end_session on changeWithoutMerge.
      // The integrator owns session lifecycle in manual mode.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      await h.instance.deviceId.changeWithoutMerge('manualNextUser');
      await flushTick(120);
      // No closing end_session emitted in manual mode.
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    // --- Ports of Android DeviceIdTests.java ---

    // temporaryIdModeEnabled_1: state machine toggling of offline mode.
    it('offlineMode_toggleSequence', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('dsd'); });
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      expect(h.instance.deviceId.isOfflineMode()).assertFalse();

      await h.instance.deviceId.enableOfflineMode();
      expect(h.instance.deviceId.isOfflineMode()).assertTrue();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      await h.instance.deviceId.setID('ff');
      expect(h.instance.deviceId.getID()).assertEqual('ff');
      expect(h.instance.deviceId.isOfflineMode()).assertFalse();

      await h.instance.deviceId.enableOfflineMode();
      expect(h.instance.deviceId.isOfflineMode()).assertTrue();

      await h.instance.deviceId.setID('12');
      expect(h.instance.deviceId.getID()).assertEqual('12');
      expect(h.instance.deviceId.isOfflineMode()).assertFalse();

      await h.instance.deviceId.setID('34');
      expect(h.instance.deviceId.getID()).assertEqual('34');
      expect(h.instance.deviceId.isOfflineMode()).assertFalse();
    });

    // temporaryIdModeEnabled_2: init directly in offline mode via config flag.
    it('offlineMode_initInOfflineMode', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(h.instance.deviceId.isOfflineMode()).assertTrue();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(h.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
    });

    // getType matrix: dev-supplied / temporary / generated.
    it('getType_matrixOnInit', 0, async () => {
      const a: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('dsd'); });
      expect(a.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      const b: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(b.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      const c: Harness = await buildHarness();
      expect(c.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(c.instance.deviceId.getID().length > 0).assertTrue();
    });

    // getId: developer supplied / temporary / generated.
    it('getId_matrixOnInit', 0, async () => {
      const a: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('abc'); });
      expect(a.instance.deviceId.getID()).assertEqual('abc');

      const b: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(b.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);

      const c: Harness = await buildHarness();
      expect(c.instance.deviceId.getID().length > 0).assertTrue();
    });

    // changeToCustomIdAndEnterTempIDMode: round-trip dev-supplied → temp → dev-supplied.
    it('changeIdAndEnterTempMode_roundTrip', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('abc'); });
      expect(h.instance.deviceId.getID()).assertEqual('abc');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      await h.instance.deviceId.changeWithoutMerge('123');
      expect(h.instance.deviceId.getID()).assertEqual('123');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      await h.instance.deviceId.enableOfflineMode();
      expect(h.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      await h.instance.deviceId.changeWithoutMerge('aaa');
      expect(h.instance.deviceId.getID()).assertEqual('aaa');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // --- Ports of Android ModuleDeviceIdTests.java ---

    // setID_sameCustom: setting the identical id is ignored.
    it('setID_sameCustomIsNoOp', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('commonDeviceId'); });
      expect(h.instance.deviceId.getID()).assertEqual('commonDeviceId');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      await h.instance.deviceId.setID('commonDeviceId');
      await flushTick(60);
      expect(h.instance.deviceId.getID()).assertEqual('commonDeviceId');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
    });

    // setID_custom: replacing a developer-supplied id.
    it('setID_replacesCustomId', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('commonDeviceId'); });
      await h.instance.deviceId.setID('NEW_ID');
      expect(h.instance.deviceId.getID()).assertEqual('NEW_ID');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // setID: sdk-generated → dev-supplied, then null/empty/same no-ops.
    it('setID_fromGeneratedThenNoOpInputs', 0, async () => {
      const h: Harness = await buildHarness();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);

      await h.instance.deviceId.setID('NEW_ID');
      expect(h.instance.deviceId.getID()).assertEqual('NEW_ID');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      // Empty string should be ignored.
      await h.instance.deviceId.setID('');
      expect(h.instance.deviceId.getID()).assertEqual('NEW_ID');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      // Setting the same current id should be ignored.
      await h.instance.deviceId.setID(h.instance.deviceId.getID());
      expect(h.instance.deviceId.getID()).assertEqual('NEW_ID');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // --- Ports of Android ScenarioDeviceIdInitTests.java ---
    // First-init cases are covered by existing tests; the "followup init" cases
    // verify that a second init with the same storage rehydrates the first id.
    // buildHarness creates fresh storage per harness, so these ports seed the
    // storage manually from the first harness's persisted values.

    // Helper: build a second CountlyInstance wired to the same InMemoryStorage
    // as the first harness. This simulates a cold restart, the second instance's
    // init() reads the first harness's persisted cly_device_id / cly_device_id_type
    // state before picking an id. (buildHarness otherwise creates a fresh storage
    // per harness; this helper exists because several follow-up-init tests need
    // shared storage to exercise the re-init code paths.)
    const rehydrateWith = async (
      first: Harness,
      configure?: (cfg: TestableCountlyConfig) => void,
      prepareNetwork?: (network: FakeNetwork) => void
    ): Promise<Harness> => {
      const logger: Logger = new Logger();
      const network: FakeNetwork = new FakeNetwork(logger);
      if (prepareNetwork) prepareNetwork(network);
      const config: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      config.logging.enableLogging();
      if (configure) configure(config);
      const instance: CountlyInstance = new CountlyInstance(config, first.storage, network);
      await instance.init();
      return new Harness(instance, first.storage, network, config, logger);
    };

    // followupInitPrevCustomProvidedNothing: custom stored, nothing supplied next → stored id wins.
    it('followup_prevCustom_providedNothing_keepsStored', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('hjk'); });
      expect(first.instance.deviceId.getID()).assertEqual('hjk');
      expect(first.storage.dump()['cly_device_id']).assertEqual('hjk');
      expect(first.storage.dump()['cly_device_id_type']).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevCustomProvidedCustomId: custom stored, custom supplied next → stored wins.
    it('followup_prevCustom_providedCustom_keepsStored', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('hjk'); });
      // Reuse first harness's storage values to simulate a re-init, we don't have a
      // shared-storage helper, so we manually replay the device-id keys into a fresh one.
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('zxc'); });
      expect(second.instance.deviceId.getID()).assertEqual('hjk');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevCustomProvidedTempId: custom stored, temp requested next → stored wins.
    it('followup_prevCustom_providedTempMode_keepsStored', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('hjk'); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(second.instance.deviceId.getID()).assertEqual('hjk');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevNothingProvidedNothing: generated stored, nothing supplied → stored wins.
    it('followup_prevGenerated_providedNothing_keepsStored', 0, async () => {
      const first: Harness = await buildHarness();
      const initial: string = first.instance.deviceId.getID();
      const second: Harness = await rehydrateWith(first);
      expect(second.instance.deviceId.getID()).assertEqual(initial);
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    // followupInitPrevNothingProvidedCustomId: generated stored, custom supplied → stored wins.
    it('followup_prevGenerated_providedCustom_keepsStored', 0, async () => {
      const first: Harness = await buildHarness();
      const initial: string = first.instance.deviceId.getID();
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('1qwe'); });
      expect(second.instance.deviceId.getID()).assertEqual(initial);
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    // followupInitPrevNothingProvidedTempId: generated stored, temp requested → stored wins.
    it('followup_prevGenerated_providedTempMode_keepsStored', 0, async () => {
      const first: Harness = await buildHarness();
      const initial: string = first.instance.deviceId.getID();
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(second.instance.deviceId.getID()).assertEqual(initial);
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    // followupInitPrevTempIdProvidedNothing: offline mode stored, nothing supplied, stays offline.
    it('followup_prevOffline_providedNothing_staysOffline', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(first.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      const second: Harness = await rehydrateWith(first);
      // Offline mode carries over from the previous run until a device ID is set.
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(second.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
    });

    // followupInitPrevTempIdProvidedCustomId: temp stored, custom supplied → custom wins.
    it('followup_prevTemp_providedCustom_usesCustom', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('uio'); });
      expect(second.instance.deviceId.getID()).assertEqual('uio');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevTempIdProvidedTempId: temp stored, temp requested again → remains temp.
    it('followup_prevTemp_providedTempMode_staysTemp', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableOfflineMode(); });
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(second.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
    });

    // followupInitPrevTempIdProvidedCustomIdTempId: both supplied → custom wins over temp flag.
    it('followup_prevTemp_providedCustomAndTemp_customWins', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => {
        cfg.deviceId.enableOfflineMode();
        cfg.deviceId.setId('frt');
      });
      expect(second.instance.deviceId.getID()).assertEqual('frt');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // clearStoredDeviceId config flag forces regeneration on init.
    it('followup_clearStoredDeviceId_forcesRegen', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('old-id'); });
      expect(first.instance.deviceId.getID()).assertEqual('old-id');
      const second: Harness = await rehydrateWith(first, (cfg) => {
        cfg.deviceId.enableClearStoredDeviceId();
      });
      // Stored id is cleared; with no custom and no temp request, SDK generates a fresh UUID.
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(second.instance.deviceId.getID().length > 0).assertTrue();
      expect(second.instance.deviceId.getID() === 'old-id').assertFalse();
    });

    // --- Ports of Android TemporaryIDTests.java ---

    // rqWithTempInitWithNoID / rqWithTempInitWithCustomID: when we exit temp mode
    // at init (because stored type was temp and a custom id is picked), queued
    // requests that carry the temp placeholder are rewritten to the new id.
    it('tempExitOnInit_rewritesQueuedTempRequests_custom', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      first.network.shouldFail = true; // keep queued, don't drain
      const tempEnc: string = encodeURIComponent(TEMP_DEVICE_ID);
      await first.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${tempEnc}&aa=45`);
      await flushTick(80);

      // Simulate cold restart with the same storage, second init supplies a custom id.
      first.instance.requestQueue.halt();
      // Inspect the rewritten queue BEFORE init's post-resolveInitial drain
      // empties it. Setting shouldFail on the rehydrated network keeps the
      // request parked so peekAll has something to see; without this, the
      // first tick after resolveInitial drains the head and the test races.
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('a123d'); }, (network: FakeNetwork) => {
        network.shouldFail = true;
      });
      await flushTick(80);
      expect(second.instance.deviceId.getID()).assertEqual('a123d');
      const entries: string[] = second.instance.requestQueue.peekAll();
      const hasReal: boolean = entries.some((r: string) => r.indexOf('device_id=a123d') !== -1);
      const hasTemp: boolean = entries.some((r: string) => r.indexOf(`device_id=${tempEnc}`) !== -1);
      expect(hasReal).assertTrue();
      expect(hasTemp).assertFalse();
    });

    // rqWithTempInitWithTemp: if we re-enter temp mode, queued temp placeholders stay.
    it('tempExitOnInit_preservesPlaceholder_whenReenteringTemp', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      h.network.shouldFail = true;
      const tempEnc: string = encodeURIComponent(TEMP_DEVICE_ID);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${tempEnc}&aa=45`);
      await flushTick(80);
      const entries: string[] = h.instance.requestQueue.peekAll();
      const hasTemp: boolean = entries.some((r: string) => r.indexOf(`device_id=${tempEnc}`) !== -1);
      expect(hasTemp).assertTrue();
    });

    // --- Queue flush on exit from temp mode at runtime (setID replays queue) ---
    it('setID_fromTempMode_flushesQueuedRequests', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      // In temp mode, requests are queued but NOT sent.
      await h.instance.events.recordEvent('queued-event', null, 1, 0, 0);
      // Force the event batch into the request queue.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${encodeURIComponent(TEMP_DEVICE_ID)}&queued=1`);
      await flushTick(80);
      expect(h.network.calls.length).assertEqual(0); // nothing sent while temp

      await h.instance.deviceId.setID('realUser');
      await flushTick(120);
      expect(h.instance.deviceId.getID()).assertEqual('realUser');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      // The previously-queued request should have been rewritten with the new id and sent.
      const sentWithReal: boolean = h.network.calls.some(c => c.data.indexOf('device_id=realUser') !== -1 && c.data.indexOf('queued=1') !== -1);
      expect(sentWithReal).assertTrue();
    });

    // --- Persistence: device id survives in storage ---
    it('persistence_deviceIdWrittenToStorage', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('persisted-user'); });
      const dump: Record<string, string> = h.storage.dump();
      expect(dump['cly_device_id']).assertEqual('persisted-user');
      expect(dump['cly_device_id_type']).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    it('persistence_generatedIdWrittenToStorage', 0, async () => {
      const h: Harness = await buildHarness();
      const dump: Record<string, string> = h.storage.dump();
      expect(dump['cly_device_id']).assertEqual(h.instance.deviceId.getID());
      expect(dump['cly_device_id_type']).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    it('persistence_tempIdWrittenToStorage', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      const dump: Record<string, string> = h.storage.dump();
      expect(dump['cly_device_id']).assertEqual(TEMP_DEVICE_ID);
      expect(dump['cly_device_id_type']).assertEqual(DeviceIdType.TEMPORARY_ID);
    });

    // --- changeWithMerge emits old_device_id parameter (URL-encoded) ---
    it('changeWithMerge_paramCarriesOldId', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('oldUser'); });
      await h.instance.deviceId.changeWithMerge('mergedUser');
      await flushTick(80);
      const encodedOld: string = encodeURIComponent('oldUser');
      const hits: number = h.network.calls.filter(c => c.data.indexOf(`old_device_id=${encodedOld}`) !== -1).length;
      expect(hits).assertEqual(1);
      expect(h.instance.deviceId.getID()).assertEqual('mergedUser');
    });

    // --- Device-id change propagation round-trip: both types of listeners fire
    //     and persisted state reflects new id (verifies the Countly.ets captureRejection
    //     fan-out actually reaches modules without aborting). ---
    it('changeWithoutMerge_persistsNewIdAfterFanOut', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('before'); });
      await h.instance.deviceId.changeWithoutMerge('after');
      await flushTick(80);
      expect(h.instance.deviceId.getID()).assertEqual('after');
      const dump: Record<string, string> = h.storage.dump();
      expect(dump['cly_device_id']).assertEqual('after');
      expect(dump['cly_device_id_type']).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    it('changeWithMerge_persistsNewIdAfterFanOut', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.changeWithMerge('merged');
      await flushTick(80);
      expect(h.instance.deviceId.getID()).assertEqual('merged');
      const dump: Record<string, string> = h.storage.dump();
      expect(dump['cly_device_id']).assertEqual('merged');
      expect(dump['cly_device_id_type']).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    it('changeWithMergeWireOrder_beginSessionBeforeOldDeviceId', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('original_id'); });
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.deviceId.changeWithMerge('merged_id');
      await flushTick(80);
      assertWireOrder(h.network.calls, ['begin_session=1', 'old_device_id=']);
    });

    // --- Offline mode (dev guide: Device ID Management, Offline Mode) ---

    it('changeWithMerge_inOfflineMode_replacesPlaceholderWithoutMergeRequest', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      await h.instance.events.recordEvent('recorded_while_offline');
      await h.instance.flushEvents();
      await flushTick(60);
      expect(h.network.calls.length).assertEqual(0);
      await h.instance.deviceId.changeWithMerge('merged_after_offline');
      await flushTick(150);
      expect(h.instance.deviceId.getID()).assertEqual('merged_after_offline');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.network.findCallsWithParam(`device_id=${encodeURIComponent(TEMP_DEVICE_ID)}`).length).assertEqual(0);
      expect(h.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_while_offline') !== -1 && c.data.indexOf('device_id=merged_after_offline') !== -1)).assertTrue();
    });

    it('changeWithMerge_inTemporaryIdMode_keepsConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.deviceId.enableOfflineMode();
        cfg.consent.setRequiresConsent(true);
      });
      h.instance.consentModule.giveConsent(['events']);
      await flushTick(60);
      await h.instance.deviceId.changeWithMerge('merged_after_temporary');
      await flushTick(150);
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
    });

    it('changeWithoutMerge_inOfflineMode_replacesPlaceholderWithoutMergeRequest', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      await h.instance.events.recordEvent('recorded_while_offline');
      await h.instance.flushEvents();
      await flushTick(60);
      await h.instance.deviceId.changeWithoutMerge('real_after_offline');
      await flushTick(150);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.network.findCallsWithParam(`device_id=${encodeURIComponent(TEMP_DEVICE_ID)}`).length).assertEqual(0);
      expect(h.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_while_offline') !== -1 && c.data.indexOf('device_id=real_after_offline') !== -1)).assertTrue();
    });

    it('setID_inOfflineMode_keepsConsentAndSession', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.deviceId.enableOfflineMode();
        cfg.consent.setRequiresConsent(true);
      });
      h.instance.consentModule.giveConsent(['sessions', 'events']);
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.deviceId.setID('user_after_login');
      await flushTick(150);
      expect(h.instance.consentModule.hasConsent('sessions')).assertTrue();
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('begin_session=1') !== -1 && c.data.indexOf('device_id=user_after_login') !== -1)).assertTrue();
    });

    it('enableOfflineMode_atRuntime_worksLikeChangeWithoutMergeToThePlaceholder', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.deviceId.setId('user_before_logout');
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.instance.lifecycleForeground();
      await h.instance.events.recordEvent('pending_before_logout');
      await flushTick(60);
      await h.instance.deviceId.enableOfflineMode();
      await flushTick(60);
      expect(h.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
      const queued: string[] = h.instance.requestQueue.peekAll();
      expect(queued.some((r: string) => r.indexOf('pending_before_logout') !== -1 && r.indexOf('device_id=user_before_logout') !== -1)).assertTrue();
      expect(queued.some((r: string) => r.indexOf('end_session=1') !== -1 && r.indexOf('device_id=user_before_logout') !== -1)).assertTrue();
      expect(h.network.findCallsWithParam('pending_before_logout').length).assertEqual(0);

      // Leaving offline mode does not give the removed consent back.
      await h.instance.deviceId.disableOfflineMode('user_after_login');
      await flushTick(150);
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
      expect(h.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('pending_before_logout') !== -1 && c.data.indexOf('device_id=user_before_logout') !== -1)).assertTrue();
    });

    it('disableOfflineMode_withoutId_returnsToTheIdAndTypeBefore', 0, async () => {
      const h: Harness = await buildHarness();
      const before: string = h.instance.deviceId.getID();
      await h.instance.deviceId.enableOfflineMode();
      await h.instance.events.recordEvent('recorded_while_offline');
      await h.instance.flushEvents();
      await h.instance.deviceId.disableOfflineMode();
      await flushTick(150);
      expect(h.instance.deviceId.getID()).assertEqual(before);
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
      expect(h.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_while_offline') !== -1 && c.data.indexOf(`device_id=${encodeURIComponent(before)}`) !== -1)).assertTrue();
    });

    it('disableOfflineMode_withoutId_afterOfflineStart_generatesId', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      await h.instance.deviceId.disableOfflineMode();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(h.instance.deviceId.getID() !== TEMP_DEVICE_ID && h.instance.deviceId.getID().length > 0).assertTrue();
    });

    it('disableOfflineMode_withId_isDeveloperSuppliedWithoutMergeRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.enableOfflineMode();
      await h.instance.deviceId.disableOfflineMode('logged_in_user');
      await flushTick(100);
      expect(h.instance.deviceId.getID()).assertEqual('logged_in_user');
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(0);
    });

    it('disableOfflineMode_outsideOfflineMode_isIgnoredWithWarning', 0, async () => {
      const warnings: string[] = [];
      const h: Harness = await buildHarness((cfg) => {
        cfg.deviceId.setId('stays_the_same');
        cfg.logging.setListener((message: string, level: LogLevel): void => {
          if (level === LogLevel.WARNING) warnings.push(message);
        });
      });
      await h.instance.deviceId.disableOfflineMode('another_user');
      expect(h.instance.deviceId.getID()).assertEqual('stays_the_same');
      expect(warnings.some((w: string) => w.indexOf('disableOfflineMode, not in offline mode, ignored') !== -1)).assertTrue();
    });

    it('placeholderAsNewId_entersOfflineMode', 0, async () => {
      const a: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('developer_user'); });
      await a.instance.deviceId.setID(TEMP_DEVICE_ID);
      expect(a.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      const b: Harness = await buildHarness();
      await b.instance.deviceId.changeWithMerge(TEMP_DEVICE_ID);
      await flushTick(60);
      expect(b.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(b.network.findCallsWithParam('old_device_id=').length).assertEqual(0);

      const c: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('developer_user'); });
      await c.instance.deviceId.changeWithoutMerge(TEMP_DEVICE_ID);
      expect(c.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      const d: Harness = await buildHarness((cfg) => { cfg.deviceId.setId(TEMP_DEVICE_ID); });
      expect(d.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
    });

    it('restartInOfflineMode_keepsQueueUntilRealIdArrives', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      await first.instance.events.recordEvent('recorded_before_restart');
      await first.instance.flushEvents();
      await first.instance.stop();
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableOfflineMode(); });
      await flushTick(100);
      expect(second.network.calls.length).assertEqual(0);
      expect(second.instance.requestQueue.peekAll().some((r: string) => r.indexOf('recorded_before_restart') !== -1)).assertTrue();
      await second.instance.deviceId.setID('real_after_restart');
      await flushTick(150);
      expect(second.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_before_restart') !== -1 && c.data.indexOf('device_id=real_after_restart') !== -1)).assertTrue();
      expect(second.network.findCallsWithParam(`device_id=${encodeURIComponent(TEMP_DEVICE_ID)}`).length).assertEqual(0);
    });

    it('restartInOfflineMode_disableOfflineModeReturnsToTheIdBefore', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('user_a'); });
      await first.instance.deviceId.enableOfflineMode();
      await first.instance.stop();
      const second: Harness = await rehydrateWith(first);
      expect(second.instance.deviceId.isOfflineMode()).assertTrue();
      await second.instance.deviceId.disableOfflineMode();
      expect(second.instance.deviceId.getID()).assertEqual('user_a');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    it('restartInOfflineMode_clearStoredDeviceId_sendsHeldDataUnderNewId', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableOfflineMode(); });
      await first.instance.events.recordEvent('recorded_before_clear');
      await first.instance.flushEvents();
      await first.instance.stop();
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableClearStoredDeviceId(); });
      await flushTick(150);
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      const newId: string = encodeURIComponent(second.instance.deviceId.getID());
      expect(second.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_before_clear') !== -1 && c.data.indexOf(`device_id=${newId}`) !== -1)).assertTrue();
    });

    it('restartInOfflineMode_slowStorage_sendsNothingAtInit', 0, async () => {
      const logger: Logger = new Logger();
      const storage: SlowStorage = new SlowStorage(logger, 'test_app_key');
      const first: CountlyInstance = await launchOn(storage, new FakeNetwork(logger), (cfg: TestableCountlyConfig) => {
        cfg.deviceId.enableOfflineMode();
      });
      await first.events.recordEvent('recorded_before_restart');
      await first.flushEvents();
      await first.stop();
      const network: FakeNetwork = new FakeNetwork(logger);
      const second: CountlyInstance = await launchOn(storage, network, (cfg: TestableCountlyConfig) => {
        cfg.deviceId.enableOfflineMode();
      });
      await flushTick(100);
      expect(network.calls.length).assertEqual(0);
      expect(second.requestQueue.peekAll().some((r: string) => r.indexOf('recorded_before_restart') !== -1)).assertTrue();
      await second.stop();
    });

    it('setID_inOfflineMode_slowStorage_sendsNoPlaceholderWhileTheIdChanges', 0, async () => {
      const logger: Logger = new Logger();
      const network: FakeNetwork = new FakeNetwork(logger);
      const instance: CountlyInstance = await launchOn(new SlowStorage(logger, 'test_app_key'), network, (cfg: TestableCountlyConfig) => {
        cfg.deviceId.enableOfflineMode();
      });
      await instance.events.recordEvent('recorded_while_offline');
      await instance.flushEvents();
      await instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${encodeURIComponent(TEMP_DEVICE_ID)}&queued_last=1`);
      await instance.deviceId.setID('real_after_offline');
      await flushTick(150);
      expect(network.findCallsWithParam(`device_id=${encodeURIComponent(TEMP_DEVICE_ID)}`).length).assertEqual(0);
      expect(network.calls.some((c: RecordedCall) =>
        c.data.indexOf('recorded_while_offline') !== -1 && c.data.indexOf('device_id=real_after_offline') !== -1)).assertTrue();
      await instance.stop();
    });

    it('placeholderLeftInQueue_isSentUnderCurrentIdAtNextInit', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('queue_owner'); });
      first.instance.requestQueue.pause();
      await first.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${encodeURIComponent(TEMP_DEVICE_ID)}&left_behind=1`);
      await first.instance.stop();
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('queue_owner'); });
      await flushTick(150);
      expect(second.network.calls.some((c: RecordedCall) =>
        c.data.indexOf('left_behind=1') !== -1 && c.data.indexOf('device_id=queue_owner') !== -1)).assertTrue();
      expect(second.network.findCallsWithParam(`device_id=${encodeURIComponent(TEMP_DEVICE_ID)}`).length).assertEqual(0);
    });
  });
}
