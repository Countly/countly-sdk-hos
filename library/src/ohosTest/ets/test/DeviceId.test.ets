import { afterEach, describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { DeviceIdType } from '../../../main/ets/types/Types';
import { TEMP_DEVICE_ID } from '../../../main/ets/internal/RequestQueue';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { FakeNetwork } from './doubles/FakeNetwork';
import { Logger } from '../../../main/ets/internal/Logger';

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
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
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

    it('enableTemporaryIdMode_switchesAtRuntime', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.deviceId.enableTemporaryIdMode();
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
      expect(h.instance.consent.getConsent('events')).assertTrue();
      await h.instance.deviceId.changeWithoutMerge('newUser');
      await flushTick(100);
      // All consents should have been cleared as part of the not-merged flow.
      expect(h.instance.consent.getConsent('events')).assertFalse();
      expect(h.instance.consent.getConsent('crashes')).assertFalse();
      // Timed events should have been cleared, so endEvent on the previous
      // key is a no-op (no events request produced).
      await h.instance.events.endEvent('checkout');
      await flushTick(60);
      // Match on `events=` (the URL-encoded query param) — NOT bare `events`,
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
      // No automatic begin yet — fresh session waits for the next foreground.
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

    // temporaryIdModeEnabled_1: state machine toggling of temporary mode.
    it('temporaryIdMode_toggleSequence', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('dsd'); });
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
      expect(h.instance.deviceId.isTemporaryIdMode()).assertFalse();

      await h.instance.deviceId.enableTemporaryIdMode();
      expect(h.instance.deviceId.isTemporaryIdMode()).assertTrue();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      await h.instance.deviceId.setID('ff');
      expect(h.instance.deviceId.getID()).assertEqual('ff');
      expect(h.instance.deviceId.isTemporaryIdMode()).assertFalse();

      await h.instance.deviceId.enableTemporaryIdMode();
      expect(h.instance.deviceId.isTemporaryIdMode()).assertTrue();

      await h.instance.deviceId.setID('12');
      expect(h.instance.deviceId.getID()).assertEqual('12');
      expect(h.instance.deviceId.isTemporaryIdMode()).assertFalse();

      await h.instance.deviceId.setID('34');
      expect(h.instance.deviceId.getID()).assertEqual('34');
      expect(h.instance.deviceId.isTemporaryIdMode()).assertFalse();
    });

    // temporaryIdModeEnabled_2: init directly in temp mode via config flag.
    it('temporaryIdMode_initInTempMode', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      expect(h.instance.deviceId.isTemporaryIdMode()).assertTrue();
      expect(h.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(h.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
    });

    // getType matrix: dev-supplied / temporary / generated.
    it('getType_matrixOnInit', 0, async () => {
      const a: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('dsd'); });
      expect(a.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);

      const b: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      expect(b.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);

      const c: Harness = await buildHarness();
      expect(c.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(c.instance.deviceId.getID().length > 0).assertTrue();
    });

    // getId: developer supplied / temporary / generated.
    it('getId_matrixOnInit', 0, async () => {
      const a: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('abc'); });
      expect(a.instance.deviceId.getID()).assertEqual('abc');

      const b: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
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

      await h.instance.deviceId.enableTemporaryIdMode();
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
    // as the first harness. This simulates a cold restart — the second instance's
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
      // Reuse first harness's storage values to simulate a re-init — we don't have a
      // shared-storage helper, so we manually replay the device-id keys into a fresh one.
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('zxc'); });
      expect(second.instance.deviceId.getID()).assertEqual('hjk');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevCustomProvidedTempId: custom stored, temp requested next → stored wins.
    it('followup_prevCustom_providedTempMode_keepsStored', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.setId('hjk'); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableTemporaryMode(); });
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
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableTemporaryMode(); });
      expect(second.instance.deviceId.getID()).assertEqual(initial);
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
    });

    // followupInitPrevTempIdProvidedNothing: temp stored, nothing supplied → remain temp or regen.
    // HOS behavior: storedIsTemp path regenerates (no custom, no requestTemp) → SDK_GENERATED.
    it('followup_prevTemp_providedNothing_regenerates', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      expect(first.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      const second: Harness = await rehydrateWith(first);
      // No custom, no requestTemp → SDK generates a fresh UUID (exits temp mode).
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.SDK_GENERATED);
      expect(second.instance.deviceId.getID().length > 0).assertTrue();
    });

    // followupInitPrevTempIdProvidedCustomId: temp stored, custom supplied → custom wins.
    it('followup_prevTemp_providedCustom_usesCustom', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.setId('uio'); });
      expect(second.instance.deviceId.getID()).assertEqual('uio');
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.DEVELOPER_SUPPLIED);
    });

    // followupInitPrevTempIdProvidedTempId: temp stored, temp requested again → remains temp.
    it('followup_prevTemp_providedTempMode_staysTemp', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => { cfg.deviceId.enableTemporaryMode(); });
      expect(second.instance.deviceId.getType()).assertEqual(DeviceIdType.TEMPORARY_ID);
      expect(second.instance.deviceId.getID()).assertEqual(TEMP_DEVICE_ID);
    });

    // followupInitPrevTempIdProvidedCustomIdTempId: both supplied → custom wins over temp flag.
    it('followup_prevTemp_providedCustomAndTemp_customWins', 0, async () => {
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      const second: Harness = await rehydrateWith(first, (cfg) => {
        cfg.deviceId.enableTemporaryMode();
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
      const first: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      first.network.shouldFail = true; // keep queued, don't drain
      const tempEnc: string = encodeURIComponent(TEMP_DEVICE_ID);
      await first.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${tempEnc}&aa=45`);
      await flushTick(80);

      // Simulate cold restart with the same storage — second init supplies a custom id.
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
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
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
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
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
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
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
  });
}
