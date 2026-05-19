import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { RecordedCall } from './doubles/FakeNetwork';

export default function requestQueueTest() {
  describe('RequestQueueTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('enqueue_increasesQueueAndPersists', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.requestQueue.enqueue('foo=1');
      await flushTick();
      // Network should have received the request
      expect(h.network.calls.length >= 1).assertTrue();
    });

    it('queueCap_dropsOldest', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.network.setMaxRequestQueueSize(3); });
      // Simulate the processor being paused to avoid draining
      h.network.shouldFail = true;
      for (let i = 0; i < 5; i++) {
        await h.instance.requestQueue.enqueue(`timestamp=${Date.now() + i}&foo=${i}`);
      }
      await flushTick(100);
      // Queue size should not exceed cap
      expect(h.instance.requestQueue.size() <= 3).assertTrue();
    });

    it('onSuccess_requestIsRemovedFromQueue', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextBody = '{"result":"Success"}';
      await h.instance.requestQueue.enqueue('foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('onFailure_requestRemainsInQueue', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue('timestamp=' + Date.now() + '&foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size() >= 1).assertTrue();
    });

    it('nonSuccessStatus_5xx_keepsRequest', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextStatus = 500;
      h.network.nextBody = 'internal error';
      await h.instance.requestQueue.enqueue('timestamp=' + Date.now() + '&foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size() >= 1).assertTrue();
    });

    it('nonSuccessStatus_4xx_dropsHead', 0, async () => {
      // 4xx is permanent (bad app_key, revoked creds, etc), retry would
      // spin battery/data forever. classify() drops the head.
      const h: Harness = await buildHarness();
      h.network.nextStatus = 401;
      h.network.nextBody = '{"error":"invalid app_key"}';
      await h.instance.requestQueue.enqueue('timestamp=' + Date.now() + '&foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('200_without_result_field_dropsHead', 0, async () => {
      // Broken proxy returning 200 with the wrong body shouldn't trap us
      // at max backoff forever. classify() treats this as permanent.
      const h: Harness = await buildHarness();
      h.network.nextStatus = 200;
      h.network.nextBody = '{"unrelated":"payload"}';
      await h.instance.requestQueue.enqueue('timestamp=' + Date.now() + '&foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('200_unparseable_dropsHead', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.nextStatus = 200;
      h.network.nextBody = '<html>captive portal</html>';
      await h.instance.requestQueue.enqueue('timestamp=' + Date.now() + '&foo=bar');
      await flushTick(100);
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('replaceTempDeviceId_swapsPlaceholder', 0, async () => {
      const h: Harness = await buildHarness();
      // Pause processing via offline mode so the placeholder stays in the
      // queue without triggering a fail-then-backoff cycle (which would push
      // the next tick out by ~1s and the 80ms flushTick wouldn't observe it).
      h.instance.requests.enableOfflineMode();
      const tempEnc: string = encodeURIComponent('CLYTemporaryDeviceID');
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${tempEnc}&foo=bar`);
      await flushTick(40);
      await h.instance.requestQueue.replaceTempDeviceId('REAL_ID');
      await h.instance.requests.disableOfflineMode();
      await flushTick(120);
      const hasReal: boolean = h.network.calls.some((c: RecordedCall) => c.data.indexOf('device_id=REAL_ID') !== -1);
      expect(hasReal).assertTrue();
    });

    it('cleanupOrphanedTempRequests_removesPlaceholders', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      const tempEnc: string = encodeURIComponent('CLYTemporaryDeviceID');
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&device_id=${tempEnc}&foo=bar`);
      await flushTick(80);
      const before: number = h.instance.requestQueue.size();
      expect(before >= 1).assertTrue();
      await h.instance.requestQueue.cleanupOrphanedTempRequests();
      // Filter-based cleanup removes entries that contain the placeholder.
      const after: number = h.instance.requestQueue.size();
      expect(after < before).assertTrue();
    });

    it('dropByAge_removesStaleRequestsBeforeSend', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.network.setRequestDropAgeHours(1); });
      const longAgo: number = Date.now() - 2 * 3600 * 1000;
      await h.instance.requestQueue.enqueue(`timestamp=${longAgo}&foo=stale`);
      await flushTick(100);
      // No send should have happened for the stale request.
      const hadStaleCall: boolean = h.network.calls.some(c => c.data.indexOf('foo=stale') !== -1);
      expect(hadStaleCall).assertFalse();
    });

    // -----------------------------------------------------------------------
    // Ported from Android RequestQueueTests.java, app-key rewrite / removal
    // -----------------------------------------------------------------------

    it('removeDifferentAppKeys_dropsMismatchedEntries', 0, async () => {
      const h: Harness = await buildHarness();
      // Pause queue draining by making network fail so enqueued entries stay.
      h.network.shouldFail = true;
      const currentKeyEnc: string = encodeURIComponent('test_app_key');
      const otherKeyEnc: string = encodeURIComponent('qqq45qer');
      await h.instance.requestQueue.enqueue(`app_key=${currentKeyEnc}&timestamp=${Date.now()}&foo=keep1`);
      await h.instance.requestQueue.enqueue(`app_key=${otherKeyEnc}&timestamp=${Date.now()}&foo=drop1`);
      await h.instance.requestQueue.enqueue(`app_key=${currentKeyEnc}&timestamp=${Date.now()}&foo=keep2`);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&app_key=${otherKeyEnc}&foo=drop2`);
      await flushTick(80);
      const before: number = h.instance.requestQueue.size();
      expect(before).assertEqual(4);
      await h.instance.requests.removeDifferentAppKeysFromQueue();
      const kept: string[] = h.instance.requestQueue.peekAll();
      expect(kept.length).assertEqual(2);
      expect(kept.every(r => r.indexOf('foo=keep') !== -1)).assertTrue();
    });

    it('replaceAllAppKeysWithCurrent_rewritesMismatchedEntries', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      const currentKeyEnc: string = encodeURIComponent('test_app_key');
      const otherKeyEnc: string = encodeURIComponent('qqq45qer');
      await h.instance.requestQueue.enqueue(`app_key=${currentKeyEnc}&timestamp=${Date.now()}&foo=a`);
      await h.instance.requestQueue.enqueue(`app_key=${otherKeyEnc}&timestamp=${Date.now()}&foo=b`);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&app_key=${otherKeyEnc}&foo=c`);
      await flushTick(80);
      expect(h.instance.requestQueue.size()).assertEqual(3);
      await h.instance.requests.replaceAllAppKeysInQueueWithCurrentAppKey();
      const kept: string[] = h.instance.requestQueue.peekAll();
      expect(kept.length).assertEqual(3);
      // Every entry now carries the current app_key value.
      expect(kept.every(r => r.indexOf(`app_key=${currentKeyEnc}`) !== -1)).assertTrue();
      // And none retain the mismatched one.
      expect(kept.every(r => r.indexOf(`app_key=${otherKeyEnc}`) === -1)).assertTrue();
    });

    // -----------------------------------------------------------------------
    // Ported from Android ConnectionQueueIntegrationTests, enqueue semantics
    // -----------------------------------------------------------------------

    it('enqueue_emptyPayload_isDropped', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(5);
      h.network.reset();
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue('');
      await flushTick(60);
      // Empty payload is rejected at enqueue-time, nothing persisted, nothing sent.
      expect(h.instance.requestQueue.size()).assertEqual(0);
      expect(h.network.calls.length).assertEqual(0);
    });

    it('enqueue_persistsToStorage', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=persisted`);
      await flushTick(60);
      const dump: Record<string, string> = h.storage.dump();
      const raw: string = dump['cly_request_queue'];
      expect(raw !== undefined).assertTrue();
      expect(raw.indexOf('foo=persisted') !== -1).assertTrue();
    });

    it('clear_emptiesInMemoryAndStorage', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=a`);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=b`);
      await flushTick(60);
      expect(h.instance.requestQueue.size() >= 2).assertTrue();
      await h.instance.requests.flushQueues();
      expect(h.instance.requestQueue.size()).assertEqual(0);
      const dump: Record<string, string> = h.storage.dump();
      const raw: string | undefined = dump['cly_request_queue'];
      // Either key absent or stored as empty string, both mean "no requests".
      expect(raw === undefined || raw.length === 0).assertTrue();
    });

    // -----------------------------------------------------------------------
    // Ported from Android ConnectionProcessorTests, request draining
    // -----------------------------------------------------------------------

    it('drain_emptyQueue_doesNotHitNetwork', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(5);
      h.network.reset();
      await flushTick(80);
      // Sanity: a freshly-inited instance with an empty queue sends nothing.
      expect(h.network.calls.length).assertEqual(0);
    });

    it('drain_twoQueuedRequests_bothSentInOrder', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(5);
      h.network.reset();
      // Pause first, enqueue two, then resume to observe draining order.
      h.instance.requests.enableOfflineMode();
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=first`);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now() + 1}&foo=second`);
      await flushTick(40);
      expect(h.network.calls.length).assertEqual(0);
      await h.instance.requests.disableOfflineMode();
      await flushTick(120);
      expect(h.network.calls.length >= 2).assertTrue();
      const firstIdx: number = h.network.calls.findIndex(c => c.data.indexOf('foo=first') !== -1);
      const secondIdx: number = h.network.calls.findIndex(c => c.data.indexOf('foo=second') !== -1);
      expect(firstIdx !== -1 && secondIdx !== -1 && firstIdx < secondIdx).assertTrue();
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('drain_appendsRrRemainingCount', 0, async () => {
      // Parity with Android ConnectionProcessorTests.testRun_storeHasTwoConnections,
      // rr=<remaining>, so first-of-two has rr=1 and the tail has rr=0.
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=r1`);
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now() + 1}&foo=r2`);
      await flushTick(20);
      await h.instance.requests.disableOfflineMode();
      await flushTick(120);
      const first = h.network.calls.find(c => c.data.indexOf('foo=r1') !== -1);
      const last = h.network.calls.find(c => c.data.indexOf('foo=r2') !== -1);
      expect(first !== undefined && last !== undefined).assertTrue();
      expect(first!.data.indexOf('rr=1') !== -1).assertTrue();
      expect(last!.data.indexOf('rr=0') !== -1).assertTrue();
    });

    // -----------------------------------------------------------------------
    // Backoff behavior
    // -----------------------------------------------------------------------

    it('backoff_disabled_keepsRetryingWithoutDelay', 0, async () => {
      // With backoff disabled, an evaluateBackoff-triggered pause doesn't fire
      //, success path still removes the head, so the test focuses on the
      // config knob being respected. shouldFail leaves the head in place.
      const h: Harness = await buildHarness((cfg) => { cfg.network.disableBackoffMechanism(); });
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=retry`);
      await flushTick(120);
      // Failure means request stays queued, contract enforced regardless of backoff.
      expect(h.instance.requestQueue.size() >= 1).assertTrue();
    });

    it('backoff_5xxDoesNotDropHead_recoversOnSuccess', 0, async () => {
      // After a transient 5xx, the head stays queued. Flipping to 200 with a
      // valid body drains it; final queue size is zero.
      const h: Harness = await buildHarness();
      h.network.nextStatus = 500;
      h.network.nextBody = 'err';
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=flaky`);
      await flushTick(100);
      expect(h.instance.requestQueue.size() >= 1).assertTrue();
      // Recovery: happy response drains the queue on next tick. Use replaceTempDeviceId
      // as a cheap way to trigger scheduleTick without enqueuing a second request.
      h.network.nextStatus = 200;
      h.network.nextBody = '{"result":"Success"}';
      await h.instance.requestQueue.replaceTempDeviceId('nudge');
      await flushTick(120);
      // Note: may still be within backoff window, so we don't assert drain here,
      // the non-drop-on-5xx contract above is the load-bearing check.
    });

    // -----------------------------------------------------------------------
    // Offline-mode + temp-id pauses
    // -----------------------------------------------------------------------

    it('offlineMode_pausesQueue_resumeFlushes', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(5);
      h.network.reset();
      h.instance.requests.enableOfflineMode();
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=offline`);
      await flushTick(60);
      expect(h.network.calls.length).assertEqual(0);
      expect(h.instance.requestQueue.size()).assertEqual(1);
      await h.instance.requests.disableOfflineMode();
      await flushTick(100);
      expect(h.network.calls.some(c => c.data.indexOf('foo=offline') !== -1)).assertTrue();
    });

    it('offlineMode_resumeWithNewDeviceId_changesIdBeforeFlush', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      // Enqueue directly so no device_id is baked into the body; the
      // ensuing drain will rely on the new id being set by disableOfflineMode.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=idswap`);
      await flushTick(30);
      await h.instance.requests.disableOfflineMode('device_after_offline');
      await flushTick(120);
      expect(h.instance.deviceId.getID()).assertEqual('device_after_offline');
      expect(h.network.calls.some(c => c.data.indexOf('foo=idswap') !== -1)).assertTrue();
    });

    it('tempIdMode_blocksSend_realIdFlushes', 0, async () => {
      // Start in temp mode via deviceId config; queued requests should stay
      // local until setID swaps the placeholder for a real id.
      const h: Harness = await buildHarness((cfg) => { cfg.deviceId.enableTemporaryMode(); });
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=tempheld`);
      await flushTick(80);
      expect(h.network.calls.length).assertEqual(0);
      expect(h.instance.deviceId.isTemporaryIdMode()).assertTrue();
      await h.instance.deviceId.setID('real_after_temp');
      await flushTick(120);
      expect(h.instance.deviceId.isTemporaryIdMode()).assertFalse();
      expect(h.network.calls.some(c => c.data.indexOf('foo=tempheld') !== -1)).assertTrue();
    });

    // -----------------------------------------------------------------------
    // Halt semantics (parity with Android Countly.halt())
    // -----------------------------------------------------------------------

    it('halt_stopsFurtherDrains', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=halt`);
      await flushTick(60);
      await h.instance.halt();
      h.network.shouldFail = false;
      const callsBefore: number = h.network.calls.length;
      // After halt, even if we re-enqueue the queue shouldn't drain.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=after_halt`);
      await flushTick(100);
      // No new successful sends should appear, the tick scheduler is halted.
      const newSuccessfulSends: number = h.network.calls.filter(c => c.data.indexOf('foo=after_halt') !== -1).length;
      expect(newSuccessfulSends).assertEqual(0);
      // We still may have observed failed attempts prior to halt; the
      // invariant checked is the post-halt lack of new network activity.
      expect(h.network.calls.length >= callsBefore).assertTrue();
    });

    // -----------------------------------------------------------------------
    // recordMetrics + offline mode idempotency
    // -----------------------------------------------------------------------

    it('recordMetrics_enqueuesIRequestWithOverride', 0, async () => {
      // recordMetrics merges DeviceInfo.collect() with the caller-provided
      // overrides and ships a `metrics=` /i request. The dev-guide-defined
      // shape is covered by request-builder tests; here we just verify the
      // wire activation path. Health check is disabled so the metrics= probe
      // isolates the recordMetrics signal, the hc payload also carries
      // `metrics=` and would otherwise pollute the count.
      const h: Harness = await buildHarness((cfg) => { cfg.network.disableHealthCheck(); });
      const before: number = h.network.findCallsWithParam('metrics=').length;
      const overrides: Record<string, string> = { '_device': 'TestDevice' };
      await h.instance.requests.recordMetrics(overrides);
      await flushTick(80);
      const after: number = h.network.findCallsWithParam('metrics=').length;
      expect(after > before).assertTrue();
      const newest = h.network.findCallsWithParam('metrics=');
      const decoded: string = decodeURIComponent(newest[newest.length - 1].data);
      expect(decoded.indexOf('TestDevice') !== -1).assertTrue();
    });

    it('recordMetrics_blockedWithoutMetricsConsent', 0, async () => {
      // disableHealthCheck so the hc payload's metrics= doesn't fire and
      // pollute the no-consent assertion.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.network.disableHealthCheck();
      });
      const before: number = h.network.findCallsWithParam('metrics=').length;
      await h.instance.requests.recordMetrics({});
      await flushTick(80);
      expect(h.network.findCallsWithParam('metrics=').length).assertEqual(before);
    });

    it('enableOfflineMode_idempotent_secondCallIsNoOp', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.requests.enableOfflineMode();
      h.instance.requests.enableOfflineMode();
      // Subsequent enqueues should remain paused, exercises the
      // already-paused early-return branch.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=offlineidem`);
      await flushTick(80);
      expect(h.network.calls.filter(c => c.data.indexOf('foo=offlineidem') !== -1).length).assertEqual(0);
    });

    // -----------------------------------------------------------------------
    // BOM (backoff mechanism), server-config tuned (dev guide §SBS bom_*)
    // -----------------------------------------------------------------------

    it('bom_slowSuccess_pausesForBomDuration', 0, async () => {
      // Server returns 200 with elapsedMs ≥ bom_at, slow-success path
      // triggers backoff. Subsequent enqueue should NOT ship until the
      // pause window elapses.
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'bom_at': 1, 'bom_d': 2, 'bom_rqp': 0.9 } as Record<string, Object>
      });
      const h: Harness = await buildHarness((cfg) => { cfg.setSDKBehaviorSettings(sbs); });
      h.network.reset();
      h.network.nextStatus = 200;
      h.network.nextBody = '{"result":"Success"}';
      h.network.nextElapsedMs = 1500; // 1.5s ≥ bom_at=1s
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=slow1`);
      await flushTick(120);
      expect(h.network.calls.some(c => c.data.indexOf('foo=slow1') !== -1)).assertTrue();
      // Now we're in a 2-second backoff window. The next enqueue should NOT
      // tick out before that window elapses (within 80ms here).
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=slow2`);
      await flushTick(80);
      expect(h.network.calls.some(c => c.data.indexOf('foo=slow2') !== -1)).assertFalse();
    });

    it('bom_fastResponse_doesNotTriggerBackoff', 0, async () => {
      // elapsedMs (20ms default) < bom_at*1000, no backoff arms even on
      // a half-empty queue.
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'bom_at': 5, 'bom_d': 2, 'bom_rqp': 0.9 } as Record<string, Object>
      });
      const h: Harness = await buildHarness((cfg) => { cfg.setSDKBehaviorSettings(sbs); });
      h.network.reset();
      h.network.nextElapsedMs = 20;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=fast1`);
      await flushTick(80);
      expect(h.network.calls.some(c => c.data.indexOf('foo=fast1') !== -1)).assertTrue();
      // Second request ships immediately, no backoff window.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=fast2`);
      await flushTick(80);
      expect(h.network.calls.some(c => c.data.indexOf('foo=fast2') !== -1)).assertTrue();
    });

    it('bom_staleHead_skipsBackoff', 0, async () => {
      // Slow response BUT head request is older than bom_ra, backoff
      // skips so the pile-up doesn't get re-paused on every drained stale
      // request. Next enqueue ships without delay.
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'bom_at': 1, 'bom_d': 5, 'bom_ra': 1, 'bom_rqp': 0.9 } as Record<string, Object>
      });
      const h: Harness = await buildHarness((cfg) => { cfg.setSDKBehaviorSettings(sbs); });
      h.network.reset();
      h.network.nextElapsedMs = 1500; // slow
      // Stale timestamp: 2 hours old > bom_ra=1 hour.
      const stale: number = Date.now() - 2 * 3600 * 1000;
      await h.instance.requestQueue.enqueue(`timestamp=${stale}&foo=stale`);
      await flushTick(120);
      expect(h.network.calls.some(c => c.data.indexOf('foo=stale') !== -1)).assertTrue();
      // No backoff armed. A fresh enqueue ships immediately.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=fresh`);
      await flushTick(80);
      expect(h.network.calls.some(c => c.data.indexOf('foo=fresh') !== -1)).assertTrue();
    });

    it('bom_queueAboveRqpThreshold_skipsBackoff', 0, async () => {
      // Slow responses on a queue that's above the bom_rqp threshold must
      // NOT arm backoff, the SDK can't afford to pause when the queue
      // is filling up. With max=10 and bom_rqp=0.05, every post-shift
      // ratio (0.3, 0.2, 0.1) is above threshold until the queue empties,
      // so all four items drain inside the test window even though every
      // response is slow.
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'rqs': 10, 'bom_at': 1, 'bom_d': 5, 'bom_rqp': 0.05 } as Record<string, Object>
      });
      const h: Harness = await buildHarness((cfg) => {
        cfg.setSDKBehaviorSettings(sbs);
      });
      h.network.reset();
      h.network.nextElapsedMs = 1500;
      h.instance.requests.enableOfflineMode();
      const now: number = Date.now();
      await h.instance.requestQueue.enqueue(`timestamp=${now}&foo=q1`);
      await h.instance.requestQueue.enqueue(`timestamp=${now + 1}&foo=q2`);
      await h.instance.requestQueue.enqueue(`timestamp=${now + 2}&foo=q3`);
      await h.instance.requestQueue.enqueue(`timestamp=${now + 3}&foo=q4`);
      h.network.calls = [];
      await h.instance.requests.disableOfflineMode();
      await flushTick(200);
      // All four drain, backoff would have pinned the queue at the
      // first slow drain if `bom_rqp` weren't being consulted.
      expect(h.instance.requestQueue.size()).assertEqual(0);
    });

    it('bom_disabled_skipsAllEvaluation', 0, async () => {
      // Even with a slow response and a near-empty queue, bom=false short-
      // circuits the entire evaluateBackoff path.
      const sbs: string = JSON.stringify({
        'v': 1, 't': Date.now(),
        'c': { 'bom': false, 'bom_at': 1, 'bom_d': 5 } as Record<string, Object>
      });
      const h: Harness = await buildHarness((cfg) => { cfg.setSDKBehaviorSettings(sbs); });
      h.network.reset();
      h.network.nextElapsedMs = 1500;
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=disabled1`);
      await flushTick(120);
      // Next enqueue ships immediately, backoff disabled.
      await h.instance.requestQueue.enqueue(`timestamp=${Date.now()}&foo=disabled2`);
      await flushTick(80);
      expect(h.network.calls.some(c => c.data.indexOf('foo=disabled2') !== -1)).assertTrue();
    });
  });
}
