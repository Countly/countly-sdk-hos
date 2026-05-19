import util from '@ohos.util';

/**
 * Per-instance strictly-monotonic millisecond clock plus event-id generator.
 *
 * Two reasons this lives on the instance instead of as static state on
 * `Utils`:
 *
 *   1. **No cross-instance contamination.** Each `CountlyInstance` records
 *      events and views at its own pace. With a single process-wide
 *      counter, instance A's high-throughput burst (think 10k events in
 *      under a second) would bump the shared `lastMsTs` thousands of ms
 *      into the future, and instance B's next `recordEvent` — which
 *      should report wall-clock-now — would inherit that artificial
 *      future timestamp. Per-instance scoping keeps each instance's
 *      monotonic drift bounded by its OWN call rate.
 *
 *   2. **Test isolation.** Two harnesses inside the same test suite can
 *      record events without leaking timestamp state into each other.
 *      Before this split, a perf test that drove uniqueTimestampMs hard
 *      could leave the next unrelated test seeing artificially-future
 *      first timestamps.
 *
 * The monotonic property — every call returns a value strictly greater
 * than the previous one from the SAME clock — is preserved exactly. The
 * server relies on it for ordering events that arrive in the same batch.
 */
export class MonotonicClock {
  private lastMsTs: number = 0;

  /**
   * Strictly-monotonic millisecond timestamp. Two calls within the same
   * wall-clock millisecond return distinct values: the second one is
   * `Date.now() + 1` (and the third `+2`, etc.). Under sustained
   * high-rate calls this can drift past wall clock; the drift is
   * bounded by THIS clock's own call rate, not the process-wide rate.
   */
  public nowMs(): number {
    const ts: number = Date.now();
    if (this.lastMsTs >= ts) {
      this.lastMsTs++;
    } else {
      this.lastMsTs = ts;
    }
    return this.lastMsTs;
  }

  /**
   * Short event/view id: 16 hex chars of random UUID followed by the
   * current monotonic timestamp. Sharing the clock with `nowMs()` means
   * an id minted right after a `nowMs()` call has a trailing timestamp
   * >= that value, preserving wire-order ties between an event's `id`
   * and its `timestamp` field.
   */
  public generateEventId(): string {
    const uuid: string = util.generateRandomUUID(false).replace(/-/g, '');
    return uuid.substring(0, 16) + this.nowMs().toString();
  }
}
