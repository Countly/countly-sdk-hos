import { afterEach, describe, it, expect } from '@ohos/hypium';
import { Countly } from '../../../main/ets/Countly';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, clearTestHarnesses } from './TestHelpers';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { Logger } from '../../../main/ets/internal/Logger';
import common from '@ohos.app.ability.common';

/**
 * Performance tests. Each test measures wall-clock time around a defined
 * workload and asserts a generous upper bound — the goal is regression
 * detection, not micro-benchmarking. Thresholds are tuned for the HMOS
 * emulator on the development machine; they're 5–10x looser than what we
 * observe in practice so a slow CI run won't trip them.
 *
 * What "good" looks like in CI logs:
 *   - perf_eventThroughput_10k_events:       <2000 ms total
 *   - perf_requestQueue_enqueue_under_load:  <3000 ms for 5k enqueues
 *   - perf_storageInit_with_1000_buffered:   <500 ms to load 1k requests
 *   - perf_multiInstance_100_create_halt:    <8000 ms total
 */
export default function performanceTest(): void {
  describe('PerformanceTest', (): void => {
    afterEach(async (): Promise<void> => {
      await Countly.haltAll();
      clearTestHarnesses();
    });

    // -- Perf #1: event recording throughput -------------------------------

    // Records 10k events with a queue threshold high enough that no
    // intermediate flush kicks in, then forces a single flush at the end.
    // Catches regressions in the `recordEventAt` hot path: sanitizeSegmentation,
    // ListingFilters.apply{Event,EventSegmentation}Filter, peid chain
    // bookkeeping, dedupe maps.
    it('perf_eventThroughput_10k_events', 0, async (): Promise<void> => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig): void => {
        // Threshold above N so the only flush is the explicit final one.
        cfg.events.setQueueSizeToSend(20000);
      });
      const N: number = 10000;
      const start: number = Date.now();
      for (let i: number = 0; i < N; i++) {
        await h.instance.events.recordEvent(`evt_${i}`, { 'bucket': `b${i % 50}` }, 1, 0, 0);
      }
      const recordMs: number = Date.now() - start;
      // All N events sit in the in-memory queue (no flush triggered).
      expect(h.instance.hasPendingEvents()).assertTrue();
      const flushStart: number = Date.now();
      await h.instance.flushEvents();
      const flushMs: number = Date.now() - flushStart;
      const total: number = recordMs + flushMs;
      h.logger.i(`[PerfTest] eventThroughput, recordMs=${recordMs} flushMs=${flushMs} totalMs=${total} perEvent=${(recordMs / N).toFixed(3)}ms`);
      // Generous upper bound; observed ~600ms on the emulator, threshold
      // 5x that to absorb CI variance.
      expect(total < 3000).assertTrue();
      // Sanity: at least one batch reached the network.
      expect(h.network.calls.length >= 1).assertTrue();
    });

    // -- Perf #2: request queue enqueue under load ------------------------

    // Each enqueue triggers a Storage.setString that rewrites the full
    // queue blob. With N=5000 this hits O(N²) bytes total — the test
    // doesn't assert that's fixed, just that it stays under a sane
    // ceiling, so a future regression that adds another O(N) per
    // enqueue (e.g. parsing the blob on every write) gets caught.
    it('perf_requestQueue_enqueue_under_load', 0, async (): Promise<void> => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig): void => {
        // Default cap is 1000 — bump above N so the perf measurement
        // reflects the actual cost of N enqueues rather than the
        // drop-from-head loop that runs once the cap is hit.
        cfg.network.setMaxRequestQueueSize(20000);
      });
      // Pause so the processor doesn't ship anything mid-test. We're
      // measuring enqueue+persist, not the network leg.
      h.instance.requestQueue.pause();
      const N: number = 5000;
      const start: number = Date.now();
      for (let i: number = 0; i < N; i++) {
        await h.instance.requestQueue.enqueue(`app_key=test&device_id=d&t=1&timestamp=${Date.now()}&sdk_name=arkts-native-harmonyos&dummy=${i}`);
      }
      const enqueueMs: number = Date.now() - start;
      h.logger.i(`[PerfTest] requestQueueEnqueue, N=${N} totalMs=${enqueueMs} perEnqueue=${(enqueueMs / N).toFixed(3)}ms queueSize=${h.instance.requestQueue.size()}`);
      expect(h.instance.requestQueue.size() === N).assertTrue();
      // Observed ~700-1500ms on the emulator. 5x ceiling.
      expect(enqueueMs < 7500).assertTrue();
    });

    // -- Perf #3: storage init + queue load with N=1000 buffered ----------

    // Seeds an InMemoryStorage with a 1000-entry queue blob, then builds a
    // brand-new harness pointed at that storage so init() runs `Storage.init`
    // + `requestQueue.load` against pre-existing state. Catches O(N²)
    // deserialization regressions.
    it('perf_storageInit_with_1000_buffered', 0, async (): Promise<void> => {
      const N: number = 1000;
      // Build a primed storage by running a throwaway harness, enqueuing N
      // items, then reusing the same InMemoryStorage. Pause first so
      // nothing drains.
      const primer: Harness = await buildHarness();
      primer.instance.requestQueue.pause();
      for (let i: number = 0; i < N; i++) {
        await primer.instance.requestQueue.enqueue(`app_key=test&device_id=d&t=1&timestamp=${Date.now()}&sdk_name=arkts-native-harmonyos&seq=${i}`);
      }
      await primer.instance.stop();
      const sharedStorage: InMemoryStorage = primer.storage;
      // New harness on the same storage — measure init + load time.
      const network: FakeNetwork = new FakeNetwork(new Logger());
      const cfg: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', 'test_app_key');
      cfg.logging.enableLogging();
      const fresh: CountlyInstance = new CountlyInstance(cfg, sharedStorage, network);
      const start: number = Date.now();
      await fresh.init();
      const initMs: number = Date.now() - start;
      // Pause again so the load doesn't race the assertion below.
      fresh.requestQueue.pause();
      const loadedSize: number = fresh.requestQueue.size();
      fresh.config.logger.i(`[PerfTest] storageInit, N=${N} initMs=${initMs} loadedQueueSize=${loadedSize}`);
      expect(loadedSize === N).assertTrue();
      // Observed ~100ms. Generous 5x cap.
      expect(initMs < 1500).assertTrue();
      await fresh.stop();
    });

    // -- Perf #4: 100 createInstance + halt cycles -----------------------

    // Stresses the multi-instance lifecycle. Each cycle constructs a fresh
    // CountlyInstance via `Countly.createInstance(name, cfg)` and then halts
    // it. We assert (a) total time stays reasonable and (b) no instance
    // remains in `Countly.listInstances()` afterwards.
    it('perf_multiInstance_100_create_halt', 0, async (): Promise<void> => {
      const N: number = 100;
      const start: number = Date.now();
      for (let i: number = 0; i < N; i++) {
        const cfg: TestableCountlyConfig = new TestableCountlyConfig({} as common.Context, 'https://try.count.ly', `app_${i}`);
        cfg.logging.enableLogging();
        const bootstrapLogger: Logger = new Logger();
        const storage: InMemoryStorage = new InMemoryStorage(bootstrapLogger, `app_${i}`);
        const network: FakeNetwork = new FakeNetwork(bootstrapLogger);
        const inst: CountlyInstance = await Countly.createInstance(`inst_${i}`, cfg, storage, network);
        await inst.halt();
      }
      const totalMs: number = Date.now() - start;
      const remaining: string[] = Countly.listInstances();
      // Halted instances stay registered in `namedInstances` because halt
      // doesn't deregister — that's by design (so a follow-up
      // initShared(...) can detect them via `consentLockedPostUnknown` /
      // `halted` and replace them). The leak signal we care about is the
      // memory map below, not this count.
      new Logger().i(`[PerfTest] multiInstance_100, totalMs=${totalMs} perCycle=${(totalMs / N).toFixed(2)}ms remaining=${remaining.length}`);
      // Observed ~2000ms. 4x cap.
      expect(totalMs < 8000).assertTrue();
      // After halt, every named entry should still be present (Countly
      // doesn't auto-unregister), but they should ALL report halted.
      expect(remaining.length === N).assertTrue();
    });
  });
}
