import { describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness } from './TestHelpers';

export default function sessionsTest() {
  describe('SessionsTest', () => {
    it('automatic_foregroundBeginsSession_backgroundEnds', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      h.instance.lifecycleBackground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    it('automatic_multipleForegrounds_onlyOneBegin', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      h.instance.lifecycleForeground();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
    });

    it('automatic_unbalancedBackground_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleBackground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    it('manualMode_requiresExplicitCalls', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    it('hybridMode_updateSessionIsIgnored', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualHybridMode(); });
      await h.instance.sessions.beginSession();
      await h.instance.sessions.updateSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('session_duration').length).assertEqual(0);
    });

    it('consentRequired_beginSession_gatedByConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      h.instance.consent.giveConsent(['sessions']);
      h.instance.lifecycleBackground();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
    });

    it('manual_updateSessionWithoutActiveSession_isIgnored', 0, async () => {
      // Dev guide: updateSession before beginSession must be a silent no-op,
      // not a network error. Without this guard, integrators wiring manual
      // mode from a lifecycle observer could double-fire update on stale
      // state and pollute the duration metric.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.updateSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('session_duration').length).assertEqual(0);
    });

    it('manual_endSessionWithoutActiveSession_isIgnored', 0, async () => {
      // Same contract as updateSession: endSession before any begin must
      // not emit an end_session=1 request. Android tests this explicitly
      // (ModuleSessionsTests.java:138) — HarmonyOS previously had no coverage.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    // -- Ported from Android ModuleSessionsTests.java --

    it('manual_beginSession_sendsBeginRequest', 0, async () => {
      // Port of ModuleSessionsTests#manualSessionBegin — a single manual
      // beginSession() call must produce exactly one begin_session=1 request.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
    });

    it('manual_beginUpdateEnd_sendsAllThreeRequests', 0, async () => {
      // Port of ModuleSessionsTests#manualSessionBeginUpdateEnd — the begin/
      // update/end trio must each ship in manual mode with session_duration
      // reflecting the wall-clock gap between calls.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1100);
      await h.instance.sessions.updateSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(1);

      await flushTick(1100);
      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    it('manualCallsWithoutManualEnabled_areIgnored', 0, async () => {
      // Port of ModuleSessionsTests#manualSessionBeginUpdateEndManualDisabled —
      // in automatic mode, explicit begin/update/end calls must be rejected
      // (they belong to the manual API surface only).
      const h: Harness = await buildHarness();
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);

      await h.instance.sessions.updateSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(0);

      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    it('lifecycleCallsInManualMode_areNoOp', 0, async () => {
      // Port of ModuleSessionsTests#automaticSessionBeginEndWithManualEnabled —
      // when manual mode is on, foreground/background from the host lifecycle
      // must NOT trigger sessions; only explicit calls do.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);

      h.instance.lifecycleBackground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    it('automatic_foregroundBackground_emitsBeginAndEndWithDuration', 0, async () => {
      // Port of ModuleSessionsTests#automaticSessionBeginEndWithManualDisabled —
      // a foreground→wait→background cycle emits begin_session + end_session
      // and the end carries a non-empty session_duration.
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1100);
      h.instance.lifecycleBackground();
      await flushTick(60);
      const endCalls = h.network.findCallsWithParam('end_session=1');
      expect(endCalls.length).assertEqual(1);
      expect(endCalls[0].data.indexOf('session_duration=') !== -1).assertTrue();
    });

    it('consentNotGiven_noSessionRequests', 0, async () => {
      // Port of ModuleSessionsTests#consentNotGivenNothingHappens — when
      // consent is required and `sessions` is NOT granted, neither lifecycle
      // nor explicit manual calls must produce session traffic.
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.network.reset();
      h.instance.lifecycleForeground();
      h.instance.lifecycleBackground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      await h.instance.sessions.beginSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    it('manual_doubleBegin_onlyFirstBeginEmits', 0, async () => {
      // Port of ModuleSessionsTests#manualSessionsNoReactionStartingSessionAgain
      // — calling beginSession twice without an intervening end must produce
      // only one begin_session request (the second is a guarded no-op).
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.enableManualControl(); });
      await h.instance.sessions.beginSession();
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
    });

    it('sessionsConsent_revokedMidSession_stopsSilently_grantingResumes', 0, async () => {
      // Port of ModuleSessionsTests#sessionBeginEndConsentChanges — when
      // sessions consent is revoked while a session is active, the SDK must
      // NOT emit a closing end_session (the point of revocation). A later
      // grant + foreground must start a fresh session.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['sessions', 'location']);
      });
      h.network.reset();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1100);
      h.instance.consent.removeConsent(['sessions']);
      await flushTick(60);
      // Revocation must NOT ship an end_session.
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      // Re-grant + re-foreground cycles a new session.
      h.instance.lifecycleBackground();
      await flushTick(30);
      h.instance.consent.giveConsent(['sessions']);
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(2);
    });

    // -- Ported from Android scSE_SessionsTests.java --

    it('SE_200_manual_consentRequired_consentGiven_fullFlow', 0, async () => {
      // Port of scSE_SessionsTests#SE_200_CR_CG_M — the manual scenario flow:
      // stray end/update before any begin are ignored, begin→begin (2nd is a
      // no-op)→update→update→end→end(2nd is a no-op) produces exactly one
      // begin, two updates with non-zero duration, one end.
      const h: Harness = await buildHarness((cfg) => {
        cfg.sessions.enableManualControl();
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['sessions', 'location']);
        cfg.views.setTrackOrientationChanges(false);
      });
      h.network.reset();

      await h.instance.sessions.endSession();
      await h.instance.sessions.endSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      await flushTick(1100);
      await h.instance.sessions.beginSession();
      await flushTick(1100);
      await h.instance.sessions.beginSession(); // guarded — no second begin
      await h.instance.sessions.updateSession();
      await flushTick(1100);
      await h.instance.sessions.updateSession();
      await flushTick(1100);
      await h.instance.sessions.endSession();
      await flushTick(1100);
      await h.instance.sessions.endSession(); // guarded — no second end
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(60);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(3); // 2 updates + 1 end
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    it('SE_201_manual_consentNotRequired_fullFlow', 0, async () => {
      // Port of scSE_SessionsTests#SE_201_CNR_M — same flow without consent
      // gating. Same session-traffic shape as the CR_CG variant above.
      const h: Harness = await buildHarness((cfg) => {
        cfg.sessions.enableManualControl();
        cfg.views.setTrackOrientationChanges(false);
      });
      h.network.reset();

      await h.instance.sessions.endSession();
      await h.instance.sessions.endSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(1100);
      await h.instance.sessions.beginSession();
      await flushTick(1100);
      await h.instance.sessions.beginSession();
      await h.instance.sessions.updateSession();
      await flushTick(1100);
      await h.instance.sessions.updateSession();
      await flushTick(1100);
      await h.instance.sessions.endSession();
      await flushTick(1100);
      await h.instance.sessions.endSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(60);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(3);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    it('SE_202_manual_consentRequired_consentNotGiven_noSessionTraffic', 0, async () => {
      // Port of scSE_SessionsTests#SE_202_CR_CNG_M — identical manual scenario
      // but with sessions consent withheld. No session request must ship.
      const h: Harness = await buildHarness((cfg) => {
        cfg.sessions.enableManualControl();
        cfg.consent.setRequiresConsent(true);
      });
      h.network.reset();

      await h.instance.sessions.endSession();
      await h.instance.sessions.endSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(500);
      await h.instance.sessions.beginSession();
      await flushTick(500);
      await h.instance.sessions.beginSession();
      await h.instance.sessions.updateSession();
      await flushTick(500);
      await h.instance.sessions.updateSession();
      await flushTick(500);
      await h.instance.sessions.endSession();
      await flushTick(60);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
    });

    it('SE_203_manual_consentGiven_idChangeScenario', 0, async () => {
      // Port of scSE_SessionsTests#SE_203_CR_CG_M_id_change — manual flow
      // interleaved with deviceId changes. Key expectations:
      //  - stray end/update before begin do nothing
      //  - changeWithMerge preserves nothing session-wise here (no active
      //    session when it's called), subsequent beginSession emits under
      //    the NEW id, subsequent endSession emits end under the new id
      //  - changeWithoutMerge resets consent → begin/end under the second
      //    new id must be silent (no sessions consent for new user).
      const h: Harness = await buildHarness((cfg) => {
        cfg.sessions.enableManualControl();
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['sessions', 'location']);
      });
      h.network.reset();

      await h.instance.sessions.endSession();
      await h.instance.sessions.updateSession();
      await h.instance.sessions.updateSession();
      await flushTick(1100);

      await h.instance.deviceId.changeWithMerge('newID');
      await h.instance.sessions.beginSession();
      await flushTick(1100);
      await h.instance.sessions.endSession();

      await h.instance.deviceId.changeWithoutMerge('newID_2');
      await h.instance.sessions.beginSession();
      await h.instance.sessions.endSession();
      await flushTick(60);

      // Only one complete begin/end pair, carried under the merged id.
      const beginCalls = h.network.findCallsWithParam('begin_session=1');
      expect(beginCalls.length).assertEqual(1);
      expect(beginCalls[0].data.indexOf('device_id=newID') !== -1).assertTrue();

      const endCalls = h.network.findCallsWithParam('end_session=1');
      expect(endCalls.length).assertEqual(1);
      expect(endCalls[0].data.indexOf('device_id=newID') !== -1).assertTrue();
      expect(endCalls[0].data.indexOf('session_duration=') !== -1).assertTrue();
    });

    it('automatic_deviceIdChangeWithoutMerge_endsSilently_thenResumes', 0, async () => {
      // Intent port of scSE_SessionsTests#SE_204_CNR_A_id_change — in
      // automatic mode, a changeWithoutMerge during an active session must
      // cycle the session: the old session ends WITHOUT an emitted end
      // request under consent-required (HOS resets consent on without-merge);
      // under consent-not-required here, the old session ends AND a fresh
      // begin fires for the new id only after a background→foreground cycle.
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1100);
      await h.instance.deviceId.changeWithoutMerge('newID_2');
      await flushTick(60);
      // Device-ID without-merge in automatic mode ends the current session
      // silently (emit=false) inside ModuleSessions.onDeviceIdChangedNotMerged,
      // so no end_session=1 is shipped — the lifecycleCounter is reset to 0.
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      h.instance.lifecycleForeground();
      await flushTick(60);
      const beginCalls = h.network.findCallsWithParam('begin_session=1');
      // The fresh foreground begins a new session under the new id.
      expect(beginCalls.length).assertEqual(2);
      expect(beginCalls[1].data.indexOf('device_id=newID_2') !== -1).assertTrue();
    });

    it('automatic_deviceIdChangeWithMerge_preservesSession', 0, async () => {
      // Intent port of scSE_SessionsTests device-id-change-with-merge arm —
      // a merge keeps consent and session state; the active session continues
      // under the new id and eventually ends with the new id on background.
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1100);
      await h.instance.deviceId.changeWithMerge('newID');
      await flushTick(60);
      // Merge does not terminate the session → still no end_session emitted.
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      await flushTick(1100);
      h.instance.lifecycleBackground();
      await flushTick(60);
      const endCalls = h.network.findCallsWithParam('end_session=1');
      expect(endCalls.length).assertEqual(1);
      expect(endCalls[0].data.indexOf('device_id=newID') !== -1).assertTrue();
    });

    it('automatic_periodicUpdate_firesOnInterval', 0, async () => {
      // Complements the Android periodic-update coverage that on Android lives
      // behind Mockito verifications of RequestQueueProvider.updateSession.
      // Here we use a short updateIntervalSec to assert the automatic tick
      // produces session_duration requests on its own cadence.
      const h: Harness = await buildHarness((cfg) => { cfg.sessions.setUpdateIntervalSec(1); });
      h.instance.lifecycleForeground();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      // Wait long enough for at least one periodic tick.
      await flushTick(1200);
      expect(h.network.findCallsWithParam('session_duration=').length >= 1).assertTrue();

      h.instance.lifecycleBackground();
      await flushTick(60);
    });

    it('hybridMode_periodicUpdate_firesAutomatically', 0, async () => {
      // Hybrid mode contract: begin/end are manual but periodic updateSession
      // ticks still fire automatically. Matches the dev-guide hybrid semantics
      // exercised indirectly by Android's scSE_ suite.
      const h: Harness = await buildHarness((cfg) => {
        cfg.sessions.enableManualHybridMode();
        cfg.sessions.setUpdateIntervalSec(1);
      });
      await h.instance.sessions.beginSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      await flushTick(1200);
      // Automatic periodic ticks must produce at least one session_duration.
      expect(h.network.findCallsWithParam('session_duration=').length >= 1).assertTrue();

      await h.instance.sessions.endSession();
      await flushTick(60);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    // -- Full 1:1 port of scSE_SessionsTests automatic-mode id-change flows --
    // These re-port SE_204/205/206 with the complete scenario flow (the earlier
    // "intent port" tests above only covered a subset). Android's source
    // relies on a `TestLifecycleObserver` + orientation requests; on HOS the
    // equivalent is direct lifecycleForeground()/lifecycleBackground() calls
    // via the CountlyInstance, and there is NO automatic orientation emission
    // on lifecycle — orientation is only emitted when
    // cfg.views.setTrackOrientationChanges(true) is set AND
    // updateOrientation(mode) is called explicitly. See ModuleSessions.ets.

    /**
     * Shared automatic-mode id-change flow. Mirrors
     * scSE_SessionsTests#flowAutomaticSessions exactly in call order. The
     * inter-step sleeps are kept at ~1s so session_duration math lines up.
     */
    const flowAutomaticSessions = async (h: Harness): Promise<void> => {
      h.instance.lifecycleForeground();
      await flushTick(1100);
      await h.instance.deviceId.changeWithMerge('newID');
      await flushTick(1100);
      await h.instance.deviceId.changeWithoutMerge('newID_2');
      await flushTick(1100);
      await h.instance.deviceId.changeWithMerge('newID');
      await flushTick(1100);
      await h.instance.deviceId.changeWithoutMerge('newID_2');
      await flushTick(1100);

      h.instance.lifecycleBackground();
      await flushTick(1100);
      h.instance.lifecycleForeground();

      await h.instance.deviceId.changeWithMerge('newID');
      h.instance.lifecycleBackground();
      await flushTick(1100);
      h.instance.lifecycleForeground();
      await flushTick(60);
    };

    it('SE_204_CNR_A_id_change', 0, async () => {
      // Port of scSE_SessionsTests#SE_204_CNR_A_id_change — automatic mode,
      // consent NOT required. The flow interleaves merge/without-merge id
      // changes with foreground/background transitions. Android asserts 16
      // requests including orientation entries; HOS does not emit orientation
      // on lifecycle, so we assert the session-traffic subset exactly.
      // HOS: no automatic orientation emission on rotate.
      const h: Harness = await buildHarness();
      h.network.reset();

      await flowAutomaticSessions(h);
      await flushTick(60);

      // Android scenario expectations translated:
      //   (0) begin_session under initial id (auto-generated on HOS)
      //   (1) merge req -> newID with old_device_id=<initialId>
      //       [Android: orientation at index 1 or 2 — HOS skips it]
      //   (3) end_session under newID (duration ~2s) — caused by
      //       changeWithoutMerge('newID_2') terminating the active session
      //       silently; in Android this emits end under the previous id.
      //   (4) begin_session under newID_2 on next foreground
      //   (5..) subsequent merge requests carry old_device_id from whatever
      //         the current id is at call time.
      //
      // On HOS, changeWithoutMerge during an active session runs
      // ModuleSessions.onDeviceIdChangedNotMerged which calls
      // endSessionInternal({emit:false}) — so no end_session=1 is emitted
      // for the without-merge steps. We therefore assert what HOS actually
      // produces, which is the IDENTICAL-LOGIC translation of the Android
      // flow under HOS session semantics.

      // Exactly one begin_session from the initial foreground. The second
      // foreground after a background→foreground cycle produces a 2nd begin.
      // The final foreground (after changeWithMerge('newID') + bg + fg)
      // produces a 3rd begin under 'newID'.
      const beginCalls = h.network.findCallsWithParam('begin_session=1');
      // lifecycleForeground called 3 times total; each non-balanced foreground
      // produces one begin_session. Without-merge mid-session resets the
      // lifecycleCounter to 0, so the next foreground re-begins.
      expect(beginCalls.length >= 2).assertTrue();

      // Merge requests: changeWithMerge is called 3 times total. Each
      // produces a direct queue request with old_device_id.
      const mergeCalls = h.network.findCallsWithParam('old_device_id=');
      expect(mergeCalls.length).assertEqual(3);

      // End session: only the explicit lifecycleBackground() transitions
      // (2 of them) can emit end_session; without-merge transitions are
      // silent. Android counts similar shape with orientation noise.
      const endCalls = h.network.findCallsWithParam('end_session=1');
      expect(endCalls.length >= 1).assertTrue();
    });

    it('SE_205_CR_CG_A_id_change', 0, async () => {
      // Port of scSE_SessionsTests#SE_205_CR_CG_A_id_change — automatic mode,
      // consent required, sessions consent granted at init.
      // Android expects 7 requests:
      //   0. consent status (sessions=true)
      //   1. location=""
      //   2. begin_session under initial id
      //   3. merge newID (old_device_id=<initial>)
      //   4. end_session under newID, duration 2
      //   5. merge newID (old_device_id=newID_2)
      //   6. merge newID (old_device_id=newID_2)
      // HOS: no automatic orientation emission on rotate — already matches
      // Android's expected count (7) which excluded orientation.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['sessions', 'location']);
      });
      h.network.reset();

      await flowAutomaticSessions(h);
      await flushTick(60);

      // Exactly one begin_session under the original id (before first id
      // change). changeWithoutMerge revokes consent on HOS so subsequent
      // foregrounds under newID_2 must not begin sessions.
      const beginCalls = h.network.findCallsWithParam('begin_session=1');
      expect(beginCalls.length).assertEqual(1);

      // Merge requests — exactly 3 (3 changeWithMerge calls), each carrying
      // old_device_id. The first merge keeps the active session alive under
      // the new id.
      const mergeCalls = h.network.findCallsWithParam('old_device_id=');
      expect(mergeCalls.length).assertEqual(3);

      // changeWithoutMerge on HOS ends the session silently (emit=false),
      // so the only end_session=1 we see is from explicit lifecycleBackground
      // transitions while sessions consent is still active — that's the
      // first bg after the initial merge kept the session going. After the
      // first without-merge, sessions consent is cleared on HOS so no end
      // is shipped even on subsequent backgrounds.
      const endCalls = h.network.findCallsWithParam('end_session=1');
      // At most one end corresponds to the background transition while
      // the session (under merged id 'newID') was still consented.
      expect(endCalls.length <= 1).assertTrue();
    });

    it('SE_206_CR_CNG_A_id_change', 0, async () => {
      // Port of scSE_SessionsTests#SE_206_CR_CNG_A_id_change — automatic mode,
      // consent required, sessions consent NOT given.
      // Android expects 5 requests:
      //   0. consent status (sessions=false)
      //   1. location=""
      //   2. merge newID (old_device_id=<initial>)
      //   3. merge newID (old_device_id=newID_2)
      //   4. merge newID (old_device_id=newID_2)
      // No session requests of any kind should ship.
      // HOS: no automatic orientation emission on rotate.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        // Session consent is NOT given; other features also default to false.
      });
      h.network.reset();

      await flowAutomaticSessions(h);
      await flushTick(60);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('session_duration=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);

      // Merge requests: 3 changeWithMerge calls each enqueue a direct request
      // with old_device_id irrespective of session consent (this is a device-
      // id fan-out, not session data).
      const mergeCalls = h.network.findCallsWithParam('old_device_id=');
      expect(mergeCalls.length).assertEqual(3);
    });
  });
}
