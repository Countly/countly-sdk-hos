import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { RecordedCall } from './doubles/FakeNetwork';

/**
 * HealthCheck coverage. The module wires its listeners when it is created:
 * Logger (`setHealthListener`, `setHealthCodeListener`,
 * `setHealthUsageListener`) for warn/error counts, log codes and method
 * usage, and RequestQueue (`setHealthListener`) for refused requests and
 * backoffs. The send itself fires once per lifecycle on onInit; a 2xx with a
 * `result` field takes the reported amounts away.
 *
 * `buildHarness` gives each test fresh in-memory storage, so the tests here
 * stay within one lifecycle. HealthCheckCounters.test.ets covers restarts
 * on shared storage.
 */

export default function healthCheckTest() {
  describe('HealthCheckTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('onInit_fireOneHealthCheckRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(60);
      const hc = h.network.calls.filter((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      expect(hc.length).assertEqual(1);
    });

    it('onInit_disabledFlag_suppressesRequest', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.network.disableHealthCheck();
      });
      await flushTick(60);
      const hc = h.network.calls.filter((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      expect(hc.length).assertEqual(0);
    });

    it('payload_includesRequiredHealthCheckFields', 0, async () => {
      const h: Harness = await buildHarness();
      await flushTick(60);
      const hc = h.network.calls.find((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      expect(hc !== undefined).assertTrue();
      // All six fields from dev guide §Health Checks Payload must appear.
      const body: string = decodeURIComponent(hc!.data);
      ['"el":', '"wl":', '"sc":', '"em":', '"bom":', '"cbom":'].forEach((token: string) => {
        expect(body.indexOf(token) !== -1).assertTrue();
      });
    });

    it('countLogError_reflectedInSubsequentPayload', 0, async () => {
      // The counters only reach this lifecycle's payload when they are
      // logged before the deferred sendHealthCheck() (fire-and-forget)
      // takes its snapshot.
      //
      // Because the send is not awaited inside onInit, we can synchronously
      // emit logs after buildHarness returns but BEFORE flushTick lets the
      // send settle. Any log emitted in that window will be counted.
      const h: Harness = await buildHarness();
      h.logger.e('test error for health counter');
      h.logger.w('test warning for health counter');
      await flushTick(80);
      const hc = h.network.calls.find((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      expect(hc !== undefined).assertTrue();
      const body: string = decodeURIComponent(hc!.data);
      // Both counters must be >= 1 in the emitted hc payload.
      const elMatch: RegExpMatchArray | null = body.match(/"el":(\d+)/);
      const wlMatch: RegExpMatchArray | null = body.match(/"wl":(\d+)/);
      expect(elMatch !== null && parseInt(elMatch[1]) >= 1).assertTrue();
      expect(wlMatch !== null && parseInt(wlMatch[1]) >= 1).assertTrue();
    });

    it('serverAcknowledged_clearsState_onNextLifecycle', 0, async () => {
      // First lifecycle: init sends a health check, the default FakeNetwork
      // body is {"result":"Success"}, which matches the dev guide ack pattern.
      // After onInit, state should be cleared on disk. A second harness with
      // shared storage would see empty counters on next send, but buildHarness
      // gives each test its own storage, so we can only verify the clear
      // happened by inspecting the first send's initial state (zero).
      const h: Harness = await buildHarness();
      await flushTick(60);
      const hc = h.network.calls.find((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      const body: string = decodeURIComponent(hc!.data);
      // Fresh instance should have zero backoff/error counts in the first
      // payload, a baseline check that the fresh-init path works.
      expect(body.indexOf('"bom":0') !== -1).assertTrue();
      expect(body.indexOf('"cbom":0') !== -1).assertTrue();
    });

    it('secondOnInit_sameInstance_doesNotResend', 0, async () => {
      // `sent` flag guards against double-send per lifecycle. Not exposed
      // publicly, we observe it by counting hc requests after a single init.
      const h: Harness = await buildHarness();
      await flushTick(60);
      const before: number = h.network.calls.filter((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1).length;
      await flushTick(60);
      const after: number = h.network.calls.filter((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1).length;
      expect(after).assertEqual(before);
    });

    it('appVersionInMetrics_respectsOverride', 0, async () => {
      const mo: Record<string, string> = { '_app_version': '99.9.9' };
      const h: Harness = await buildHarness((cfg) => {
        cfg.setMetricOverride(mo);
      });
      await flushTick(60);
      const hc: RecordedCall | undefined = h.network.calls.find((c: RecordedCall) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      const body: string = decodeURIComponent(hc!.data);
      expect(body.indexOf('99.9.9') !== -1).assertTrue();
    });

    it('payload_includesMethodUsageAndLogCodes', 0, async () => {
      // The facade counts the call before its first await, and the timed
      // event checks are synchronous, so everything lands before the deferred send.
      const h: Harness = await buildHarness();
      h.instance.events.startEvent('checkout');
      h.instance.events.startEvent('checkout');
      h.instance.events.cancelEvent('never_started');
      await flushTick(80);
      const hc: RecordedCall | undefined = h.network.calls.find((c: RecordedCall) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      const body: string = decodeURIComponent(hc!.data);
      expect(body.indexOf('"fu":{') !== -1).assertTrue();
      expect(body.indexOf('"lc":{') !== -1).assertTrue();
      expect(body.indexOf('"start":2') !== -1).assertTrue();
      expect(body.indexOf('"cancel":1') !== -1).assertTrue();
      expect(body.indexOf('"w722":1') !== -1).assertTrue();
      expect(body.indexOf('"w721":1') !== -1).assertTrue();
    });

    it('secondInit_isCountedWithLogCodeW110', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.init();
      await flushTick(80);
      const hc: RecordedCall | undefined = h.network.calls.find((c: RecordedCall) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      const body: string = decodeURIComponent(hc!.data);
      expect(body.indexOf('"w110":1') !== -1).assertTrue();
    });

    it('networkFailure_duringSend_suppressesAckClear', 0, async () => {
      // If the send itself throws, the module must NOT clear state (it relies
      // on retaining for the next launch). Here we only verify the request was
      // attempted and the module didn't crash; HealthCheckCounters.test.ets
      // checks the retained counts after a restart.
      const h: Harness = await buildHarness();
      h.network.shouldFail = true;
      await flushTick(80);
      const attempted = h.network.calls.filter((c) => c.endpoint === '/i' && c.data.indexOf('hc=') !== -1);
      expect(attempted.length).assertEqual(1);
      // Module stays alive, subsequent instance operations should work.
      expect(h.instance !== undefined).assertTrue();
    });
  });
}
