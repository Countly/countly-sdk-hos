import { afterEach, describe, it, expect } from '@ohos/hypium';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { Countly } from '../../../main/ets/Countly';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, clearTestHarnesses } from './TestHelpers';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { Logger } from '../../../main/ets/internal/Logger';
import { LogLevel } from '../../../main/ets/types/Types';
import common from '@ohos.app.ability.common';

/**
 * Leak tests. Each test measures process memory (PSS via `hidebug.getPss`)
 * at "before" and "after" markers, asserts that growth stays under a
 * generous threshold, and verifies structural invariants (timer handles
 * back to null, listener cleared, etc.).
 *
 * PSS readings are noisy on the emulator — V8 GC pauses, JIT tier-up, and
 * heap fragmentation all show up as 100-500 KB jitter even between
 * identical idle samples. Thresholds are set well above that floor so a
 * passing run doesn't depend on luck, while a real leak (Map/Array that
 * grows without bound) blows past easily.
 *
 * Memory unit: `hidebug.getPss()` returns a bigint in KB. We carry it as
 * `number` everywhere and normalise to bytes for threshold math so deltas
 * are readable in MB.
 */

const KB: number = 1024;
const MB: number = 1024 * 1024;

function rssBytes(): number {
  try {
    const pssKb: bigint = hidebug.getPss();
    return Number(pssKb) * KB;
  } catch (err) {
    return 0;
  }
}

/**
 * Best-effort GC nudge — there's no `gc()` in ArkTS, but yielding the event
 * loop a few times lets V8 finish any short-lived collections that were
 * already queued. Calling this on either side of a sample tightens the
 * delta against incidental garbage from the test harness itself.
 */
async function settle(): Promise<void> {
  for (let i: number = 0; i < 3; i++) {
    await flushTick(20);
  }
}

export default function leakTest(): void {
  describe('LeakTest', (): void => {
    afterEach(async (): Promise<void> => {
      await Countly.haltAll();
      clearTestHarnesses();
    });

    // -- Leak #5: event-queue PSS drift over many batches -----------------

    // 100 batches of 100 events each. Threshold low enough to catch a
    // per-event leak (e.g. an undisposed Map entry in dedup tracking)
    // but well above the GC jitter floor.
    it('leak_eventQueue_pssDrift_100_batches', 0, async (): Promise<void> => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig): void => {
        // Flush every batch.
        cfg.events.setQueueSizeToSend(100);
      });
      await settle();
      const before: number = rssBytes();
      const BATCHES: number = 100;
      const PER_BATCH: number = 100;
      for (let b: number = 0; b < BATCHES; b++) {
        for (let i: number = 0; i < PER_BATCH; i++) {
          await h.instance.events.recordEvent(`leak_evt_${i}`, { 'idx': `${i}`, 'batch': `${b}` }, 1, 0, 0);
        }
        // Ensure each batch's enqueued request resolves before moving on
        // so the FakeNetwork queue doesn't accumulate `RecordedCall`
        // objects faster than they're consumed.
        await flushTick(10);
      }
      await settle();
      const after: number = rssBytes();
      const deltaMb: number = (after - before) / MB;
      h.logger.i(`[LeakTest] eventQueue, beforeKB=${(before / KB).toFixed(0)} afterKB=${(after / KB).toFixed(0)} deltaMB=${deltaMb.toFixed(2)} totalEvents=${BATCHES * PER_BATCH}`);
      // Observed ~1-3 MB drift across runs. 10 MB cap so we trip only on
      // a real per-event retain.
      expect(deltaMb < 10).assertTrue();
      // After all flushes, the event queue should be empty.
      expect(h.instance.hasPendingEvents()).assertFalse();
    });

    // -- Leak #6: stop/init cycle leak -----------------------------------

    // 50 lifecycle cycles on the SHARED instance via initShared → halt.
    // Each cycle creates a fresh CountlyInstance, fully wires every
    // module, then tears it down. Catches:
    //   - LifecycleObserver not deregistering (ApplicationContext on()
    //     would otherwise leak an observer per cycle)
    //   - Timer handles staying live on the detached instance
    //   - any module holding a back-reference to `core` that survives
    //     halt (preventing GC of the instance).
    it('leak_stopInit_50_cycles', 0, async (): Promise<void> => {
      // Warm up once so the first-cycle JIT/cache costs don't show up
      // in the delta.
      {
        const warm: Harness = await buildHarness();
        await warm.instance.halt();
      }
      await settle();
      const before: number = rssBytes();
      const CYCLES: number = 50;
      for (let c: number = 0; c < CYCLES; c++) {
        const h: Harness = await buildHarness();
        // Record one event so each cycle exercises the full plumbing,
        // not just init → halt.
        await h.instance.events.recordEvent(`cycle_${c}`, null, 1, 0, 0);
        await flushTick(5);
        await h.instance.halt();
        // Drop the closure-held reference so the underlying instance
        // can be GC'd. The harness array still pins it until afterEach
        // clears it, but the inner SDK objects (modules, fakes,
        // observers) should be unreachable past this scope.
      }
      // Clear retained harness refs before measuring so the GC has a
      // chance to reclaim per-cycle allocations.
      clearTestHarnesses();
      await settle();
      const after: number = rssBytes();
      const deltaMb: number = (after - before) / MB;
      new Logger().i(`[LeakTest] stopInit_50_cycles, beforeKB=${(before / KB).toFixed(0)} afterKB=${(after / KB).toFixed(0)} deltaMB=${deltaMb.toFixed(2)}`);
      // 50 cycles is a meaningful churn; cap at 15 MB to leave room for
      // V8 generational drift while still catching a per-cycle leak
      // that compounds linearly.
      expect(deltaMb < 15).assertTrue();
    });

    // -- Leak #7: timer cleanup audit on halt ----------------------------

    // After halt(), every internally-armed timer handle must be back to
    // null. Aggregated via CountlyInstance.hasAnyActiveTimers().
    // Additionally: after halt, no further wire calls should fire — wait
    // a generous interval to catch a setInterval that survived.
    it('leak_timer_cleanup_after_halt', 0, async (): Promise<void> => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig): void => {
        // Force a consent change so the 1s coalesce timer in ModuleConsent
        // arms — this is the timer most likely to leak across halt.
        cfg.consent.setRequiresConsent(true);
      });
      // Trigger a coalesced consent snapshot so the consent timer is armed.
      // The public facade only exposes give/removeConsentAll; we go through
      // the internal module to arm just the events-consent flip (which
      // schedules the 1s coalesce timer via setConsentInternal).
      h.instance.consentModule.giveConsent(['events']);
      // Health check's setTimeout(0) and configuration's interval are
      // already armed from buildHarness's init path.
      await flushTick(5);
      // At this point at least one of the four owners should report active.
      // (HC's setTimeout(0) may have already fired into the queue, so we
      // don't strictly require this; the key assertion is the post-halt
      // null-state.)
      const callsBeforeHalt: number = h.network.calls.length;
      await h.instance.halt();
      expect(h.instance.hasAnyActiveTimers()).assertFalse();
      // Wait longer than the consent coalesce timer (1s), the HC initial
      // send timer (0ms), and a typical SBS refresh interval kick-off.
      // If any survived halt, it would queue a request here.
      await flushTick(1500);
      // No new wire activity since halt.
      expect(h.network.calls.length === callsBeforeHalt).assertTrue();
      // Timer state still null after the wait.
      expect(h.instance.hasAnyActiveTimers()).assertFalse();
    });

    // -- Leak #8: listener pile-up via repeated setListener ---------------

    // Logger holds a single listener reference; calling setListener N
    // times must keep it at 1 (each call REPLACES the prior). The check
    // is structural — even without RSS instrumentation, we can verify
    // that 1000 sets followed by one trigger calls the latest exactly
    // once. RSS delta is a secondary signal.
    it('leak_listener_pileup_1000_sets', 0, async (): Promise<void> => {
      const logger: Logger = new Logger();
      logger.setEnabled(false); // suppress console noise from this run
      await settle();
      const before: number = rssBytes();
      let lastCallCount: number = 0;
      let latestListenerCalled: boolean = false;
      for (let i: number = 0; i < 1000; i++) {
        const idx: number = i;
        logger.setListener((_msg: string, _lvl: LogLevel): void => {
          // Each setListener overwrites — only the LAST listener should
          // ever fire. Bumping `lastCallCount` per-invocation lets us
          // assert exactly one fire happened.
          if (idx === 999) {
            latestListenerCalled = true;
          }
          lastCallCount++;
        });
      }
      logger.i('trigger');
      // The newest listener fired exactly once; the 999 replaced ones
      // are gone, not piled up.
      expect(latestListenerCalled).assertTrue();
      expect(lastCallCount === 1).assertTrue();
      // Drop the listener; the closure-captured `idx` and arrays
      // should be GC-eligible.
      logger.setListener(null);
      await settle();
      const after: number = rssBytes();
      const deltaMb: number = (after - before) / MB;
      new Logger().i(`[LeakTest] listenerPileup, deltaMB=${deltaMb.toFixed(2)}`);
      // 1000 closures of trivial shape should not leak more than 5 MB.
      expect(deltaMb < 5).assertTrue();
    });
  });
}
