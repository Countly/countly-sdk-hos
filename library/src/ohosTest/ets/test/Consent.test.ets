import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertValidBaseParams, assertWireOrder, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { CountlyFeature, CountlyFeatureNames } from '../../../main/ets/types/Types';

/** Exhaustive list of features exposed by the HOS SDK. Used to drive
 *  all-features-consented / all-denied assertions ported from Android
 *  ModuleConsentTests. */
const ALL_FEATURES: string[] = [
  CountlyFeature.SESSIONS,
  CountlyFeature.EVENTS,
  CountlyFeature.VIEWS,
  CountlyFeature.LOCATION,
  CountlyFeature.CRASHES,
  CountlyFeature.USERS,
  CountlyFeature.PUSH,
  CountlyFeature.STAR_RATING,
  CountlyFeature.REMOTE_CONFIG,
  CountlyFeature.FEEDBACK,
  CountlyFeature.CLICKS,
  CountlyFeature.SCROLLS,
  CountlyFeature.CONTENT,
  CountlyFeature.METRICS,
  CountlyFeature.FORMS
];

export default function consentTest() {
  describe('ConsentTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('consentNotRequired_allGranted', 0, async () => {
      const h: Harness = await buildHarness();
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.instance.consentModule.hasConsent('views')).assertTrue();
      expect(h.instance.consent.checkAllConsent()).assertTrue();
    });

    it('consentRequired_initialState_allDenied', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
      expect(h.instance.consentModule.hasConsent('views')).assertFalse();
      expect(h.instance.consent.checkAllConsent()).assertFalse();
    });

    it('giveConsent_turnsFeatureOn', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent(['events']);
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.instance.consentModule.hasConsent('views')).assertFalse();
    });

    it('removeConsent_turnsFeatureOff', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent(['events', 'views']);
      h.instance.consentModule.removeConsent(['views']);
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.instance.consentModule.hasConsent('views')).assertFalse();
    });

    it('giveAllConsents_inInitialConfig', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      expect(h.instance.consent.checkAllConsent()).assertTrue();
    });

    it('giveConsentAll_removeConsentAll', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consent.giveConsentAll();
      expect(h.instance.consent.checkAllConsent()).assertTrue();
      h.instance.consent.removeConsentAll();
      expect(h.instance.consent.checkAllConsent()).assertFalse();
    });

    it('featureGroup_toggleAllAtOnce', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.createFeatureGroup('activity', ['sessions', 'events', 'views']);
      h.instance.consentModule.setConsentFeatureGroup('activity', true);
      expect(h.instance.consentModule.hasConsent('sessions')).assertTrue();
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      expect(h.instance.consentModule.hasConsent('views')).assertTrue();
      h.instance.consentModule.setConsentFeatureGroup('activity', false);
      expect(h.instance.consentModule.hasConsent('sessions')).assertFalse();
    });

    it('coalescedRequest_oneSnapshotPerBurst', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent(['events']);
      h.instance.consentModule.giveConsent(['views']);
      h.instance.consentModule.giveConsent(['sessions']);
      // Wait past the 1s coalesce window.
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(1);
    });

    it('setConsent_booleanDispatcher', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.setConsent(['events'], true);
      expect(h.instance.consentModule.hasConsent('events')).assertTrue();
      h.instance.consentModule.setConsent(['events'], false);
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
    });

    it('deviceIdChangeNotMerged_doesNotSendConsentSnapshotRequest', 0, async () => {
      // When the device id changes without merge, consent is reset internally
      // (old user's grants don't carry to the new user) — but the SDK must
      // NOT emit a consent= snapshot request: that would be attributed to
      // the new user and implicitly imply the new user granted/denied
      // whatever the old user had. Dev guide §Consent; matches Android
      // ModuleConsent.java:244 behavior.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      // Absorb the initial giveAll snapshot request.
      await flushTick(1200);
      const before: number = h.network.findCallsWithParam('consent=').length;

      await h.instance.deviceId.changeWithoutMerge('new_user');
      // Wait past the coalesce window so any would-be snapshot fires.
      await flushTick(1200);
      const after: number = h.network.findCallsWithParam('consent=').length;
      expect(after).assertEqual(before);
      // Sanity check: internal consent state WAS reset (new user starts with
      // no consents until the integrator grants them again).
      expect(h.instance.consentModule.hasConsent('events')).assertFalse();
    });

    // Ported from Android ModuleConsentTests#usingValidFeatureList — HOS
    // exposes the feature name list via CountlyFeatureNames; assert the
    // in-test ALL_FEATURES list matches exactly.
    it('validateFeatureNameList_matchesSdkExport', 0, async () => {
      expect(ALL_FEATURES.length).assertEqual(CountlyFeatureNames.length);
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(ALL_FEATURES[i]).assertEqual(CountlyFeatureNames[i]);
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentWithoutConsentGiven —
    // requiresConsent=true, no initial grants → every feature is denied.
    it('enableConsentWithoutConsentGiven_allFeaturesDenied', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertFalse();
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentGiveAll — config-time
    // `giveAll()` grants every feature at init time.
    it('enableConsentGiveAll_allFeaturesGranted', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertTrue();
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentRemoveAfter — toggle
    // all on via config, removeConsentAll, then giveConsentAll. Each step
    // should flip every feature together.
    it('enableConsent_removeAllThenGiveAll_togglesEveryFeature', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertTrue();
      }
      h.instance.consent.removeConsentAll();
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertFalse();
      }
      h.instance.consent.giveConsentAll();
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertTrue();
      }
    });

    // Ported from Android ModuleConsentTests#checkSettingConsentAfterInit —
    // grant features one by one and after each grant verify only the
    // already-granted prefix reports true. checkAllConsent() should be true
    // only once every feature has been granted.
    it('checkSettingConsentAfterInit_incrementalGrants', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      expect(h.instance.consent.checkAllConsent()).assertFalse();
      for (let a = 0; a < ALL_FEATURES.length; a++) {
        h.instance.consentModule.giveConsent([ALL_FEATURES[a]]);
        for (let b = 0; b < ALL_FEATURES.length; b++) {
          if (b <= a) {
            expect(h.instance.consentModule.hasConsent(ALL_FEATURES[b])).assertTrue();
          } else {
            expect(h.instance.consentModule.hasConsent(ALL_FEATURES[b])).assertFalse();
          }
        }
      }
      expect(h.instance.consent.checkAllConsent()).assertTrue();
    });

    // Ported from Android ModuleConsentTests#validateFeatureNames — feature
    // wire-format values must never silently change.
    it('validateFeatureNameValues_wireFormat', 0, async () => {
      expect(CountlyFeature.SESSIONS).assertEqual('sessions');
      expect(CountlyFeature.EVENTS).assertEqual('events');
      expect(CountlyFeature.VIEWS).assertEqual('views');
      expect(CountlyFeature.LOCATION).assertEqual('location');
      expect(CountlyFeature.CRASHES).assertEqual('crashes');
      expect(CountlyFeature.USERS).assertEqual('users');
      expect(CountlyFeature.PUSH).assertEqual('push');
      expect(CountlyFeature.STAR_RATING).assertEqual('star-rating');
      expect(CountlyFeature.FEEDBACK).assertEqual('feedback');
      expect(CountlyFeature.REMOTE_CONFIG).assertEqual('remote-config');
      expect(CountlyFeature.SCROLLS).assertEqual('scrolls');
      expect(CountlyFeature.CLICKS).assertEqual('clicks');
      expect(CountlyFeature.CONTENT).assertEqual('content');
      expect(CountlyFeature.METRICS).assertEqual('metrics');
      expect(CountlyFeature.FORMS).assertEqual('forms');
    });

    // Ported from Android ModuleConsentTests#initTimeNoConsentRequiredRQ —
    // when consent is NOT required no consent= snapshot is ever emitted
    // (behavior is implicit: everything is consented, no snapshot needed).
    it('noConsentRequired_noConsentSnapshotRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    // Ported from Android ModuleConsentTests#initTimeNoConsentGivenRQ — when
    // consent is required and no grants are provided, init does not need to
    // emit a snapshot (HOS only sends on state changes, and no change has
    // occurred yet from the default all-false baseline).
    it('consentRequired_noGrantsGiven_noInitSnapshot', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    // Post-init coalesced grants emit a single consent= snapshot whose JSON
    // payload reflects the granted features as true and the rest as false.
    // (Replaces the deprecated init-time setEnabled granular path.)
    it('consentRequired_postInitGrants_emitsSnapshotWithFullState', 0, async () => {
      const granted: string[] = [CountlyFeature.CLICKS, CountlyFeature.PUSH, CountlyFeature.USERS, CountlyFeature.FEEDBACK];
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      h.instance.consentModule.giveConsent(granted);
      await flushTick(1200);
      const calls = h.network.findCallsWithParam('consent=');
      expect(calls.length).assertEqual(1);
      const data: string = calls[0].data;
      // Granted features should appear with true, omitted ones with false.
      // Data is URL-encoded JSON so quote characters are escaped (%22).
      for (let i = 0; i < granted.length; i++) {
        const needle: string = `%22${granted[i]}%22%3Atrue`;
        expect(data.indexOf(needle) !== -1).assertTrue();
      }
      // A feature not in the granted list should be present as false.
      const notGranted: string = `%22${CountlyFeature.SESSIONS}%22%3Afalse`;
      expect(data.indexOf(notGranted) !== -1).assertTrue();
    });

    // Regression: the init-time consent snapshot must be enqueued BEFORE
    // begin_session. The constructor schedules the snapshot via a 1-second
    // coalesce timer (correct for runtime dialog toggles); init() short-
    // circuits that timer with `flushInitialConsentIfPending()` so the queue
    // ends up with [consent, begin_session, ...] rather than [begin_session,
    // consent, ...]. Without that flush, the typical sub-second init wallclock
    // means begin_session lands before the consent timer fires.
    //
    // Also locks in: every shipped request carries a well-formed base-param
    // bag (app_key, device_id, t, timestamp>0, hour 0..23, dow 0..6, tz,
    // sdk_name, sdk_version, av).
    it('initTimeConsent_precedesBeginSession_inWireOrder', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      // Wire order — consent first, begin_session second. Other init-time
      // requests (sc/hc) may interleave; assertWireOrder tolerates that.
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1']);
      // Every recorded call carries a valid base-param bag.
      for (let i = 0; i < h.network.calls.length; i++) {
        assertValidBaseParams(h.network.calls[i]);
      }
    });

    // Verify the coalesced snapshot contains the CURRENT full state (not a
    // delta). After giving then removing a feature, the final snapshot
    // should reflect the final true/false per feature.
    it('snapshotReflectsFullState_afterMultipleChanges', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent([CountlyFeature.EVENTS, CountlyFeature.VIEWS, CountlyFeature.SESSIONS]);
      h.instance.consentModule.removeConsent([CountlyFeature.VIEWS]);
      await flushTick(1200);
      const calls = h.network.findCallsWithParam('consent=');
      expect(calls.length).assertEqual(1);
      const data: string = calls[0].data;
      expect(data.indexOf(`%22${CountlyFeature.EVENTS}%22%3Atrue`) !== -1).assertTrue();
      expect(data.indexOf(`%22${CountlyFeature.SESSIONS}%22%3Atrue`) !== -1).assertTrue();
      expect(data.indexOf(`%22${CountlyFeature.VIEWS}%22%3Afalse`) !== -1).assertTrue();
    });

    // Feature groups expand on hasConsent too: querying the group name
    // returns true only when every member has consent. Complements the
    // existing featureGroup_toggleAllAtOnce test.
    it('featureGroup_hasConsentAggregatesMembers', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.createFeatureGroup('activity', [CountlyFeature.SESSIONS, CountlyFeature.EVENTS, CountlyFeature.VIEWS]);
      h.instance.consentModule.setConsentFeatureGroup('activity', true);
      expect(h.instance.consentModule.hasConsent('activity')).assertTrue();
      h.instance.consentModule.removeConsent([CountlyFeature.EVENTS]);
      // One member revoked → the group-level query should now be false.
      expect(h.instance.consentModule.hasConsent('activity')).assertFalse();
    });

    // Granting remote-config consent with automatic triggers enabled fires a
    // downloadAllKeys call. Observable on the wire as a method=rc request.
    it('grantRemoteConfig_withAutomaticTriggers_firesDownload', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.remoteConfig.enableAutomaticTriggers();
      });
      const before: number = h.network.findCallsWithParam('method=rc').length;
      h.instance.consentModule.giveConsent([CountlyFeature.REMOTE_CONFIG]);
      await flushTick(200);
      const after: number = h.network.findCallsWithParam('method=rc').length;
      expect(after > before).assertTrue();
    });

    // Repeated identical grants are no-ops — no additional snapshot is
    // emitted if the effective state doesn't change (diff is empty).
    it('duplicateGrant_doesNotEmitExtraSnapshot', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent([CountlyFeature.EVENTS]);
      await flushTick(1200);
      const firstCount: number = h.network.findCallsWithParam('consent=').length;
      expect(firstCount).assertEqual(1);
      // Same grant again — no-op.
      h.instance.consentModule.giveConsent([CountlyFeature.EVENTS]);
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(firstCount);
    });

    // When requiresConsent=false, giveConsent / removeConsent are ignored
    // (every feature stays implicitly consented). No snapshot is emitted.
    it('noConsentRequired_mutationsAreNoOps', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.consentModule.removeConsent([CountlyFeature.EVENTS]);
      h.instance.consent.removeConsentAll();
      expect(h.instance.consentModule.hasConsent(CountlyFeature.EVENTS)).assertTrue();
      expect(h.instance.consent.checkAllConsent()).assertTrue();
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    // Unknown consent mode: SDK collects telemetry into the queue but the
    // queue is paused, so nothing reaches the wire until the integrator
    // resolves the unknown state via give/removeConsentAll.
    it('unknownConsentMode_implies_requires_and_pauses_queue', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      expect(h.config.consent.requires).assertTrue();
      // Every feature internally granted so modules actually buffer data.
      expect(h.instance.consent.checkAllConsent()).assertTrue();

      const direct: Record<string, string> = { 'custom_unknown': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      await flushTick(200);
      // Queue holds the request locally.
      expect(h.instance.requestQueue.size() > 0).assertTrue();
      // But nothing was actually sent.
      expect(h.network.findCallsWithParam('custom_unknown=value').length).assertEqual(0);
    });

    it('unknownConsentMode_removeConsentAll_dropsBufferAndHalts', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      const direct: Record<string, string> = { 'custom_unknown_remove': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      expect(h.instance.requestQueue.size() > 0).assertTrue();

      h.instance.consent.removeConsentAll();
      // Resolve chain is async (halt + module onHalts + clear).
      await flushTick(300);

      expect(h.instance.requestQueue.size()).assertEqual(0);
      expect(h.network.findCallsWithParam('custom_unknown_remove=value').length).assertEqual(0);
      // Flag cleared so a re-init wouldn't re-enter unknown mode by accident.
      expect(h.instance.config.unknownConsentMode).assertFalse();
    });

    it('unknownConsentMode_giveConsentAll_keepsBufferAndHalts', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      const direct: Record<string, string> = { 'custom_unknown_give': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      const before: number = h.instance.requestQueue.size();
      expect(before > 0).assertTrue();

      h.instance.consent.giveConsentAll();
      await flushTick(300);

      // Queue preserved so a subsequent re-init can drain it. Halt drained
      // events/sessions/etc. into the queue too, so size may grow but never
      // shrink in the giveAll path.
      expect(h.instance.requestQueue.size() >= before).assertTrue();
      // No requests went out from this halted instance.
      expect(h.network.findCallsWithParam('custom_unknown_give=value').length).assertEqual(0);
      expect(h.instance.config.unknownConsentMode).assertFalse();
    });
  });
}
