import { afterEach, describe, it, expect } from '@ohos/hypium';
import common from '@ohos.app.ability.common';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, assertValidBaseParams, assertWireOrder, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { CountlyFeature, CountlyFeatureNames, SegmentationMap, RCDownloadCallback } from '../../../main/ets/types/Types';
import { ConsentConfig } from '../../../main/ets/CountlyConfig';

function fakeContext(): common.Context { return {} as common.Context; }

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
      // (old user's grants don't carry to the new user), but the SDK must
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

    // Ported from Android ModuleConsentTests#usingValidFeatureList, HOS
    // exposes the feature name list via CountlyFeatureNames; assert the
    // in-test ALL_FEATURES list matches exactly.
    it('validateFeatureNameList_matchesSdkExport', 0, async () => {
      expect(ALL_FEATURES.length).assertEqual(CountlyFeatureNames.length);
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(ALL_FEATURES[i]).assertEqual(CountlyFeatureNames[i]);
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentWithoutConsentGiven,
    // requiresConsent=true, no initial grants → every feature is denied.
    it('enableConsentWithoutConsentGiven_allFeaturesDenied', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertFalse();
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentGiveAll, config-time
    // `giveAll()` grants every feature at init time.
    it('enableConsentGiveAll_allFeaturesGranted', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      for (let i = 0; i < ALL_FEATURES.length; i++) {
        expect(h.instance.consentModule.hasConsent(ALL_FEATURES[i])).assertTrue();
      }
    });

    // Ported from Android ModuleConsentTests#enableConsentRemoveAfter, toggle
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

    // Ported from Android ModuleConsentTests#checkSettingConsentAfterInit,
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

    // Ported from Android ModuleConsentTests#validateFeatureNames, feature
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

    // Ported from Android ModuleConsentTests#initTimeNoConsentRequiredRQ,
    // when consent is NOT required no consent= snapshot is ever emitted
    // (behavior is implicit: everything is consented, no snapshot needed).
    it('noConsentRequired_noConsentSnapshotRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    // Ported from Android ModuleConsentTests#initTimeNoConsentGivenRQ, when
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
      // Wire order, consent first, begin_session second. Other init-time
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

    // Repeated identical grants are no-ops, no additional snapshot is
    // emitted if the effective state doesn't change (diff is empty).
    it('duplicateGrant_doesNotEmitExtraSnapshot', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent([CountlyFeature.EVENTS]);
      await flushTick(1200);
      const firstCount: number = h.network.findCallsWithParam('consent=').length;
      expect(firstCount).assertEqual(1);
      // Same grant again, no-op.
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

    // removeConsentAll from UCM: erase buffered data, ship a revocation
    // snapshot (all-false consent), keep the instance running, and lock
    // future runtime consent changes ("consent is set per init").
    it('unknownConsentMode_removeConsentAll_clearsShipsRevocationAndLocks', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      const direct: Record<string, string> = { 'custom_unknown_remove': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      expect(h.instance.requestQueue.size() > 0).assertTrue();

      h.instance.consent.removeConsentAll();
      // Resolve chain: phase1 (notify) + clear + phase2 (flush snapshot) + resume.
      await flushTick(300);

      // Queue is empty: buffered data was erased, then the revocation
      // snapshot was enqueued + shipped on resume.
      expect(h.instance.requestQueue.size()).assertEqual(0);
      // The buffered custom request never reached the wire.
      expect(h.network.findCallsWithParam('custom_unknown_remove=value').length).assertEqual(0);
      // Exactly one consent= snapshot shipped, the revocation. It carries
      // every feature as false (URL-encoded JSON contains "events":false etc.).
      const consentCalls = h.network.findCallsWithParam('consent=');
      expect(consentCalls.length).assertEqual(1);
      expect(consentCalls[0].data.indexOf('%22events%22%3Afalse') !== -1).assertTrue();
      expect(consentCalls[0].data.indexOf('%22sessions%22%3Afalse') !== -1).assertTrue();
      // Internal flags transitioned correctly.
      expect(h.instance.config.unknownConsentMode).assertFalse();
      expect(h.instance.config.consentLockedPostUnknown).assertTrue();
      // Instance is NOT halted, SDK keeps running for normal "no consent" ops.
      expect(h.instance.config.halted).assertFalse();
      // Internal consent state shows all-denied (the revocation propagated).
      expect(h.instance.consent.checkAllConsent()).assertFalse();
    });

    // giveConsentAll from UCM: "network calls can start", unsilence the
    // transport, resume the queue, and the data buffered during the unknown
    // phase drains naturally to the server. Instance keeps running.
    it('unknownConsentMode_giveConsentAll_shipsBufferedData', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      const direct: Record<string, string> = { 'custom_unknown_give': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      expect(h.instance.requestQueue.size() > 0).assertTrue();

      h.instance.consent.giveConsentAll();
      // Allow the queue to tick + drain.
      await flushTick(200);

      // Buffered data reached the wire.
      expect(h.network.findCallsWithParam('custom_unknown_give=value').length).assertEqual(1);
      // The init-time consent snapshot (all-granted, from initialConsentAll=true)
      // also drained, it was sitting at the front of the buffered queue.
      const consentCalls = h.network.findCallsWithParam('consent=');
      expect(consentCalls.length).assertEqual(1);
      expect(consentCalls[0].data.indexOf('%22events%22%3Atrue') !== -1).assertTrue();
      // Instance is NOT halted, runs normally with full consent.
      expect(h.instance.config.halted).assertFalse();
      expect(h.instance.config.unknownConsentMode).assertFalse();
      expect(h.instance.config.consentLockedPostUnknown).assertFalse();
      // A fresh request post-resolve ships immediately.
      const post: Record<string, string> = { 'post_resolve_give': 'value' };
      await h.instance.requests.addDirectRequest(post);
      await flushTick(80);
      expect(h.network.findCallsWithParam('post_resolve_give=value').length).assertEqual(1);
    });

    // After UCM resolves via removeConsentAll, the runtime consent surface
    // is sealed. Any subsequent give/removeConsentAll runtime call is a
    // no-op with a "consent is set per init" warning. The only way to
    // re-enable consent is a fresh init.
    it('unknownConsentMode_revokeThenGive_ignoredPerInitLock', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      // Revoke from UCM, sets the lock.
      h.instance.consent.removeConsentAll();
      await flushTick(300);
      expect(h.instance.config.consentLockedPostUnknown).assertTrue();
      expect(h.instance.consent.checkAllConsent()).assertFalse();
      const consentCallsAfterRevoke: number = h.network.findCallsWithParam('consent=').length;

      // Subsequent runtime grant is rejected by the lock.
      h.instance.consent.giveConsentAll();
      await flushTick(1200);

      // Internal state still denies all consent, the grant did NOT apply.
      expect(h.instance.consent.checkAllConsent()).assertFalse();
      // No new consent= snapshot shipped (would indicate the grant went through).
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(consentCallsAfterRevoke);
      // Symmetrically, removeConsentAll post-lock is also a no-op (no-op redundant
      // but exercised here to lock in the bidirectional block).
      h.instance.consent.removeConsentAll();
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(consentCallsAfterRevoke);
    });

    // After a UCM revoke, the instance keeps running (no halt). The integrator
    // can continue to interact with the SDK, but every consent-gated module
    // operation is rejected by the normal consent-required guard (NOT by the
    // halt gate). Direct-request paths gated on `hasAnyConsent` similarly drop.
    it('unknownConsentMode_revoke_sdkKeepsRunningWithoutConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
        cfg.events.setQueueSizeToSend(1);
      });
      h.instance.consent.removeConsentAll();
      await flushTick(300);
      expect(h.instance.config.halted).assertFalse();

      const consentCallsBefore: number = h.network.findCallsWithParam('consent=').length;

      // Try to use the SDK post-revoke. Each call is gated by the
      // consent-required guard inside the module (NOT by halt or post-unknown
      // lock), so it logs and returns without emitting a wire request.
      await h.instance.events.recordEvent('post_revoke_evt');
      await h.instance.views.startView('post_revoke_view', null);
      await h.instance.crashes.recordHandledException(new Error('x'), null);
      await flushTick(120);

      expect(h.network.findCallsWithParam('post_revoke_evt').length).assertEqual(0);
      expect(h.network.findCallsWithParam('post_revoke_view').length).assertEqual(0);
      // Consent= traffic count is unchanged, no new snapshots since the lone revocation.
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(consentCallsBefore);
    });

    // Realistic-traffic variant of the buffering test: confirms that ordinary
    // recordEvent traffic (not just synthetic addDirectRequest) sits locally
    // while unknown mode is active. Drives a foreground so the events queue
    // flushes via the session/lifecycle path the way a real app would.
    it('unknownConsentMode_recordEvent_bufferedNotSent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
        cfg.events.setQueueSizeToSend(1); // flush every event immediately to the request queue
      });
      await h.instance.events.recordEvent('unknown_mode_evt');
      h.instance.lifecycleForeground();
      await flushTick(120);
      // Event must be locally queued, either as a pending events= request OR
      // as part of the request queue, but never on the wire.
      expect(h.network.findCallsWithParam('unknown_mode_evt').length).assertEqual(0);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      // The combined event + session traffic produced at least one queued entry.
      expect(h.instance.requestQueue.size() > 0).assertTrue();
    });

    // ConsentConfig builder convention: every setter returns the config so
    // calls can be chained. enableUnknownConsentMode is no exception.
    it('enableUnknownConsentMode_isChainable', 0, () => {
      const cfg: TestableCountlyConfig = new TestableCountlyConfig(fakeContext(), 'https://x', 'k');
      const returned: ConsentConfig = cfg.consent.enableUnknownConsentMode();
      // Returns the same ConsentConfig so fluent chaining works.
      expect(returned === cfg.consent).assertTrue();
      // The builder also flips requiresConsent on as a side effect (implied).
      expect(cfg.consent.requires).assertTrue();
      expect(cfg.consent.unknownMode).assertTrue();
    });

    // Defensive: resolveUnknownConsent is on the SdkCore interface so any
    // module can technically call it. If it fires when the instance isn't
    // actually in unknown mode it must be a no-op (warning log, no halt).
    it('resolveUnknownConsent_outsideUnknownMode_isNoOp', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      // Let init traffic settle so post-call network state isn't ambiguous.
      await flushTick(120);
      // Direct call bypassing the consent module's unknown-mode branch.
      await h.instance.resolveUnknownConsent(false);
      // Instance is still alive: a fresh direct request must reach the wire
      // (would NOT, if the no-op guard had mistakenly halted the instance).
      const direct: Record<string, string> = { 'after_noop_resolve': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      await flushTick(80);
      expect(h.network.findCallsWithParam('after_noop_resolve=value').length).assertEqual(1);
    });

    // Dart-parity: SBS fetch + Health Check are gated by UCM at module
    // entry (no `executeOperational` bypass). The init-time fetch +
    // periodic timer in ModuleConfiguration skip while UCM is active, and
    // the deferred `setTimeout(0)` health check in ModuleHealthCheck is
    // never scheduled. Asserts neither endpoint reaches the wire during
    // UCM. See brain note `ucm-hc-sbs-gate` (countly-sdk-dart) for the
    // cross-SDK policy.
    it('unknownConsentMode_deferredHCAndSBS_doNotFireDuringUCM', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      await flushTick(200);
      // No SBS fetch (/o/sdk?method=sc), no health-check (/i?hc=).
      const sbsCalls: number = h.network.findCallsWithParam('method=sc').length;
      const hcCalls: number = h.network.findCallsWithParam('hc=').length;
      expect(sbsCalls).assertEqual(0);
      expect(hcCalls).assertEqual(0);
    });

    // On UCM exit via `giveConsentAll`, the silencer is lifted and both
    // SBS + HC are fired fire-and-forget BEFORE the grant branch (which
    // resumes the queue and drains buffered telemetry). The fire-and-
    // forget triggers are visible on the wire by the time the buffered
    // give-path traffic has drained. Asserts BOTH operational requests
    // landed.
    it('unknownConsentMode_giveExit_firesHCAndSBS', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      await flushTick(120);
      expect(h.network.findCallsWithParam('method=sc').length).assertEqual(0);
      expect(h.network.findCallsWithParam('hc=').length).assertEqual(0);

      h.instance.consent.giveConsentAll();
      await flushTick(300);

      // Both deferred operational requests now on the wire.
      expect(h.network.findCallsWithParam('method=sc').length >= 1).assertTrue();
      expect(h.network.findCallsWithParam('hc=').length >= 1).assertTrue();
    });

    // Same as the give path, but for revoke. Dart's policy: HC + SBS
    // fire BEFORE the grant/revoke branch, so the revocation path also
    // gets them out — even though the queue is cleared afterward. The
    // fire-and-forget triggers go through the unsilenced Network before
    // any queue.clear() runs.
    it('unknownConsentMode_revokeExit_firesHCAndSBS', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
      });
      await flushTick(120);
      expect(h.network.findCallsWithParam('method=sc').length).assertEqual(0);
      expect(h.network.findCallsWithParam('hc=').length).assertEqual(0);

      h.instance.consent.removeConsentAll();
      await flushTick(400);

      // HC + SBS fired on the revoke branch too (before phase1/phase2).
      expect(h.network.findCallsWithParam('method=sc').length >= 1).assertTrue();
      expect(h.network.findCallsWithParam('hc=').length >= 1).assertTrue();
      // And the all-false consent snapshot still shipped at the end.
      const consentCalls = h.network.findCallsWithParam('consent=');
      expect(consentCalls.length).assertEqual(1);
      expect(consentCalls[0].data.indexOf('%22events%22%3Afalse') !== -1).assertTrue();
    });

    // Defense-in-depth: ModuleConfiguration (SBS fetch), ModuleHealthCheck
    // (health report), and ModuleRemoteConfig (auto-download) all call
    // `network.execute` DIRECTLY, they bypass the RequestQueue pause.
    // Unknown mode silences the Network itself plus module-level UCM
    // gates skip even attempting these. Exercises the typical SDK
    // lifecycle (init, foreground, an event, a direct request) and
    // asserts the FakeNetwork records zero calls.
    it('unknownConsentMode_silencesAllDirectNetworkCalls', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.enableUnknownConsentMode();
        // Force events to push through to the request queue immediately so
        // the "buffered locally, nothing on wire" contract is exercised end-
        // to-end (not only the queue, but the Network transport).
        cfg.events.setQueueSizeToSend(1);
      });
      // Trigger the typical hot paths: events, sessions (lifecycle), direct.
      await h.instance.events.recordEvent('silenced_evt');
      h.instance.lifecycleForeground();
      const direct: Record<string, string> = { 'silenced_direct': 'value' };
      await h.instance.requests.addDirectRequest(direct);
      await flushTick(200);

      // Zero network calls of any kind, init-time (SBS / HC) plus runtime
      // (events / begin_session / direct). All blocked.
      expect(h.network.calls.length).assertEqual(0);
    });

    // Regression: after the instance is halted via `instance.halt()` (or
    // `Countly.haltAll()`), every user-facing module mutator AND every gated
    // instance-level method must short-circuit. Original report: `recordEvent`
    // kept growing the in-memory event queue for 30+ seconds after halt. The
    // fix is a `config.halted` gate set at the top of `halt()` and checked
    // by every user-facing entry via `ModuleBase.rejectIfHalted(...)` plus
    // matching guards on `CountlyInstance.lifecycleForeground/Background/
    // setServerURL/...`. NOTE: UCM resolution does NOT halt anymore; this
    // test exercises explicit `halt()` only.
    //
    // Parameterized over every gated entry point so a future refactor that
    // drops a gate anywhere in the SDK fails this test (per test-guidelines:
    // one dense test, many assertions).
    it('postHalt_moduleMutatorsAreNoOp', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
        cfg.events.setQueueSizeToSend(100); // do NOT auto-flush, we want to inspect the in-memory event queue directly
      });
      // Halt the instance directly (the post-halt gate is independent of UCM).
      await h.instance.halt();
      expect(h.instance.config.halted).assertTrue();

      const pendingBefore: boolean = h.instance.hasPendingEvents();
      const queueSizeBefore: number = h.instance.requestQueue.size();
      const networkCallsBefore: number = h.network.calls.length;

      // Every gated entry point across every module + the instance-level
      // gated methods. Each must early-return; no state mutation, no wire.
      // Order does not matter, we assert the aggregate state at the end.
      const empty: SegmentationMap = {};
      const directParams: Record<string, string> = { 'post_halt_direct': 'value' };
      const metricOverride: Record<string, string> = { 'post_halt_metric': '1' };
      // Properly-typed RC download callback so the registration call type-checks
      // even though it's about to be rejected by the halt gate.
      const rcCallback: RCDownloadCallback = (): void => { /* gated, never fires */ };
      const gatedCalls: Array<() => Promise<void>> = [
        // EventsApi
        async (): Promise<void> => { await h.instance.events.recordEvent('post_halt_evt'); },
        async (): Promise<void> => { await h.instance.events.recordPastEvent('post_halt_past_evt', null, 1, 0, 0, Date.now()); },
        async (): Promise<void> => { h.instance.events.startEvent('post_halt_timed'); },
        async (): Promise<void> => { h.instance.events.cancelEvent('post_halt_timed'); },
        async (): Promise<void> => { await h.instance.events.endEvent('post_halt_end', null, 1, 0); },
        // SessionsApi
        async (): Promise<void> => { await h.instance.sessions.beginSession(); },
        async (): Promise<void> => { await h.instance.sessions.updateSession(); },
        async (): Promise<void> => { await h.instance.sessions.endSession(); },
        // ViewsApi
        async (): Promise<void> => { await h.instance.views.startAutoStoppedView('post_halt_view_auto', null); },
        async (): Promise<void> => { await h.instance.views.startView('post_halt_view', null); },
        async (): Promise<void> => { await h.instance.views.stopViewWithName('post_halt_view', null); },
        async (): Promise<void> => { await h.instance.views.stopViewWithID('nonexistent_id', null); },
        async (): Promise<void> => { h.instance.views.pauseViewWithID('nonexistent_id'); },
        async (): Promise<void> => { h.instance.views.resumeViewWithID('nonexistent_id'); },
        async (): Promise<void> => { await h.instance.views.stopAllViews(null); },
        async (): Promise<void> => { h.instance.views.addSegmentationToViewWithID('nonexistent_id', empty); },
        async (): Promise<void> => { h.instance.views.addSegmentationToViewWithName('nonexistent', empty); },
        async (): Promise<void> => { h.instance.views.setGlobalViewSegmentation(empty); },
        async (): Promise<void> => { h.instance.views.updateGlobalViewSegmentation(empty); },
        async (): Promise<void> => { await h.instance.views.updateOrientation('portrait'); },
        // CrashesApi
        async (): Promise<void> => { h.instance.crashes.addCrashBreadcrumb('post_halt_breadcrumb'); },
        async (): Promise<void> => { await h.instance.crashes.recordHandledException(new Error('post_halt'), null); },
        async (): Promise<void> => { await h.instance.crashes.recordUnhandledException(new Error('post_halt'), null); },
        async (): Promise<void> => { h.instance.crashes.setThreadStackProvider(null); },
        // UserProfileApi, all 13 mutators
        async (): Promise<void> => { h.instance.userProfile.setProperty('post_halt_prop', 'x'); },
        async (): Promise<void> => { h.instance.userProfile.setProperties(empty); },
        async (): Promise<void> => { h.instance.userProfile.increment('counter'); },
        async (): Promise<void> => { h.instance.userProfile.incrementBy('counter', 2); },
        async (): Promise<void> => { h.instance.userProfile.multiply('counter', 3); },
        async (): Promise<void> => { h.instance.userProfile.saveMax('hi', 10); },
        async (): Promise<void> => { h.instance.userProfile.saveMin('lo', 1); },
        async (): Promise<void> => { h.instance.userProfile.setOnce('once', 'v'); },
        async (): Promise<void> => { h.instance.userProfile.push('list', 'v'); },
        async (): Promise<void> => { h.instance.userProfile.pushUnique('set', 'v'); },
        async (): Promise<void> => { h.instance.userProfile.pull('list', 'v'); },
        async (): Promise<void> => { await h.instance.userProfile.save(); },
        async (): Promise<void> => { h.instance.userProfile.clear(); },
        // ConsentApi
        async (): Promise<void> => { h.instance.consent.giveConsentAll(); },
        async (): Promise<void> => { h.instance.consent.removeConsentAll(); },
        // ConsentModule (test-accessible per project_facade_api_surface)
        async (): Promise<void> => { h.instance.consentModule.giveConsent(['events']); },
        async (): Promise<void> => { h.instance.consentModule.removeConsent(['events']); },
        async (): Promise<void> => { h.instance.consentModule.setConsent(['events'], true); },
        async (): Promise<void> => { h.instance.consentModule.createFeatureGroup('grp', ['events']); },
        async (): Promise<void> => { h.instance.consentModule.setConsentFeatureGroup('grp', true); },
        // DeviceIdApi
        async (): Promise<void> => { await h.instance.deviceId.setID('post_halt_id'); },
        async (): Promise<void> => { await h.instance.deviceId.changeWithMerge('post_halt_merge'); },
        async (): Promise<void> => { await h.instance.deviceId.changeWithoutMerge('post_halt_no_merge'); },
        async (): Promise<void> => { await h.instance.deviceId.enableTemporaryIdMode(); },
        // LocationApi
        async (): Promise<void> => { await h.instance.location.setLocation('US', 'NYC', null, null); },
        async (): Promise<void> => { await h.instance.location.disableLocation(); },
        // RemoteConfigApi
        async (): Promise<void> => { await h.instance.remoteConfig.downloadAllKeys(null); },
        async (): Promise<void> => { await h.instance.remoteConfig.downloadSpecificKeys(['k'], null); },
        async (): Promise<void> => { await h.instance.remoteConfig.downloadOmittingKeys(['k'], null); },
        async (): Promise<void> => { await h.instance.remoteConfig.clearAllRemoteConfig(); },
        async (): Promise<void> => { h.instance.remoteConfig.registerDownloadCallback(rcCallback); },
        async (): Promise<void> => { h.instance.remoteConfig.removeDownloadCallback(rcCallback); },
        async (): Promise<void> => { await h.instance.remoteConfig.enrollIntoABTestsForKeys(['k']); },
        async (): Promise<void> => { await h.instance.remoteConfig.exitABTestsForKeys(['k']); },
        // RequestQueueApi
        async (): Promise<void> => { h.instance.requests.enableOfflineMode(); },
        async (): Promise<void> => { await h.instance.requests.disableOfflineMode(null); },
        async (): Promise<void> => { await h.instance.requests.flushQueues(); },
        async (): Promise<void> => { await h.instance.requests.replaceAllAppKeysInQueueWithCurrentAppKey(); },
        async (): Promise<void> => { await h.instance.requests.removeDifferentAppKeysFromQueue(); },
        async (): Promise<void> => { await h.instance.requests.addDirectRequest(directParams); },
        async (): Promise<void> => { await h.instance.requests.recordMetrics(metricOverride); },
        // CountlyInstance-level gated methods
        async (): Promise<void> => { h.instance.setServerURL('https://other.example.com'); },
        async (): Promise<void> => { h.instance.setExternalUrlOpener(null); },
        async (): Promise<void> => { h.instance.lifecycleForeground(); },
        async (): Promise<void> => { h.instance.lifecycleBackground(); }
      ];

      for (let i = 0; i < gatedCalls.length; i++) {
        await gatedCalls[i]();
      }
      await flushTick(60);

      // Aggregate assertion bundle, covers every gate in one shot.
      expect(h.instance.hasPendingEvents()).assertEqual(pendingBefore);
      expect(h.instance.requestQueue.size()).assertEqual(queueSizeBefore);
      expect(h.network.calls.length).assertEqual(networkCallsBefore);
      // Sanity: none of the payload tokens we tried to send ever appear on the wire.
      expect(h.network.findCallsWithParam('post_halt_evt').length).assertEqual(0);
      expect(h.network.findCallsWithParam('post_halt_view').length).assertEqual(0);
      expect(h.network.findCallsWithParam('post_halt_direct').length).assertEqual(0);
      expect(h.network.findCallsWithParam('post_halt_metric').length).assertEqual(0);
      expect(h.network.findCallsWithParam('post_halt_id').length).assertEqual(0);
    });

    // Regression for the lifecycle-fan-out leak: after halt, a manual call
    // to `lifecycleForeground` / `lifecycleBackground` (or
    // `Countly.lifecycleBackgroundAll`) used to fan out to
    // `viewsModule.onEnterBackground` which called `events.recordViewEvent`
    //, bypassing the `recordEvent` gate and queueing a `[CLY]_view` event
    // 30+ seconds after halt. The fix gates `CountlyInstance.lifecycleFg/Bg`
    // AND adds a defense-in-depth gate in `recordEventAt`.
    it('postHalt_lifecycleFanOut_doesNotQueueViewEvents', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      // Start a view so onEnterBackground would have something to slice.
      await h.instance.views.startView('home', null);
      h.instance.lifecycleForeground();
      await flushTick(60);
      // Halt directly.
      await h.instance.halt();
      const pendingAfterHalt: boolean = h.instance.hasPendingEvents();
      const viewCallsAfterHalt: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;

      // Simulate the "background all" button: fan out to the halted instance.
      h.instance.lifecycleBackground();
      h.instance.lifecycleForeground();
      await flushTick(60);

      // No new in-memory events queued (would be 1+ from the auto-slice path
      // pre-fix). Also no NEW [CLY]_view requests landed on the wire post-halt.
      expect(h.instance.hasPendingEvents()).assertEqual(pendingAfterHalt);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(viewCallsAfterHalt);
    });

  });
}
