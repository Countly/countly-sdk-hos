import common from '@ohos.app.ability.common';
import { expect } from '@ohos/hypium';
import { ContentConfig, CountlyConfig, FeedbackConfig, PushConfig } from '../../../main/ets/CountlyConfig';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork, RecordedCall } from './doubles/FakeNetwork';
import { Logger } from '../../../main/ets/internal/Logger';

/** Shared test rig. Exposes the CountlyInstance along with the fakes so tests
 *  can inspect recorded traffic and storage state. */
export class Harness {
  public instance: CountlyInstance;
  public storage: InMemoryStorage;
  public network: FakeNetwork;
  public config: TestableCountlyConfig;
  public logger: Logger;

  constructor(instance: CountlyInstance, storage: InMemoryStorage, network: FakeNetwork, config: TestableCountlyConfig, logger: Logger) {
    this.instance = instance;
    this.storage = storage;
    this.network = network;
    this.config = config;
    this.logger = logger;
  }
}

/**
 * Test-only widening of `CountlyConfig`. The disabled-module sub-configs
 * (`content`, `feedback`, `push`) are `protected` on the production class so
 * integrators can't accidentally use them while their backing modules are
 * disabled — but tests still need to populate them to exercise the wiring.
 * Promote via getters under `*ForTest` names so the test code flags itself
 * as test code, not production setup.
 */
export class TestableCountlyConfig extends CountlyConfig {
  public get contentForTest(): ContentConfig { return this.content; }
  public get feedbackForTest(): FeedbackConfig { return this.feedback; }
  public get pushForTest(): PushConfig { return this.push; }
}

/** A non-null fake context placeholder — the in-memory storage ignores it. */
function fakeContext(): common.Context {
  return {} as common.Context;
}

/**
 * Module-level registry of harnesses built during the current test. Lets a
 * single `afterEach` hook validate every recorded call without having to
 * thread the harness through closure variables in every `it()`. Cleared by
 * `clearTestHarnesses()` (called from each describe-block's afterEach).
 */
const __testHarnesses: Harness[] = [];

/**
 * Build and init a CountlyInstance wired to an InMemoryStorage + FakeNetwork.
 * The caller may mutate the returned CountlyConfig before/after init; for
 * shared-instance state isolation each harness gets a fresh storage instance.
 */
export async function buildHarness(
  configure?: (cfg: TestableCountlyConfig) => void,
  prepareNetwork?: (network: FakeNetwork) => void
): Promise<Harness> {
  // Bootstrap logger for storage/network initialization. This logger does NOT
  // get wired to the SDK — once the CountlyInstance is constructed, the SDK
  // uses its own internal logger (instance.config.logger). Tests should call
  // h.logger.* to interact with that one (HealthCheck listens on it).
  const bootstrapLogger: Logger = new Logger();
  const storage: InMemoryStorage = new InMemoryStorage(bootstrapLogger, 'test_app_key');
  const network: FakeNetwork = new FakeNetwork(bootstrapLogger);
  // Optional pre-init network seed — for tests that need a specific canned
  // response on the init-time SC fetch (`/o/sdk?method=sc`) or the init-time
  // healthcheck. Without this hook the fake network's defaults are used.
  if (prepareNetwork) prepareNetwork(network);
  const config: TestableCountlyConfig = new TestableCountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
  config.logging.enableLogging();
  if (configure) configure(config);
  const instance: CountlyInstance = new CountlyInstance(config, storage, network);
  await instance.init();
  // Expose the SDK's actual logger so tests that exercise log-driven
  // instrumentation (HealthCheck counters, log listeners) hit the right
  // instance. A separate bootstrap logger here would mean h.logger.e()
  // bumps a logger nobody listens to.
  const h: Harness = new Harness(instance, storage, network, config, instance.config.logger);
  __testHarnesses.push(h);
  return h;
}

/**
 * Validate every recorded call across all harnesses built during the current
 * test. Skips entries that don't look like real `RequestBuilder.baseParams()`
 * output — RequestQueue tests deliberately enqueue raw strings (e.g.
 * `'app_key=foo&timestamp=...&drop=1'`) that omit most base params. Both
 * `app_key=` and `sdk_name=` must be present for a call to count as a real
 * SDK request worth validating; `sdk_name` is added exclusively by
 * `RequestBuilder.baseParams()`, so it's a reliable RB-fingerprint.
 */
export function assertAllRecordedCallsValid(): void {
  for (let i = 0; i < __testHarnesses.length; i++) {
    const calls: RecordedCall[] = __testHarnesses[i].network.calls;
    for (let j = 0; j < calls.length; j++) {
      if (calls[j].data.indexOf('app_key=') === -1) continue;
      if (calls[j].data.indexOf('sdk_name=') === -1) continue;
      assertValidBaseParams(calls[j]);
    }
  }
}

/** Drop the harness registry at end of test. Pair with afterEach. */
export function clearTestHarnesses(): void {
  __testHarnesses.length = 0;
}

export async function flushTick(ms: number = 50): Promise<void> {
  await new Promise<void>((resolve: () => void) => setTimeout(() => resolve(), ms));
}

/**
 * Parse a URL-encoded request body (POST data or GET query) into a Record.
 * URL-decodes both keys and values. Use this in tests to assert specific
 * param values cleanly instead of grepping the raw query string.
 */
export function parseQueryParams(body: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (body.length === 0) return out;
  const pairs: string[] = body.split('&');
  for (let i = 0; i < pairs.length; i++) {
    const eq: number = pairs[i].indexOf('=');
    if (eq === -1) continue;
    const k: string = decodeURIComponent(pairs[i].substring(0, eq));
    const v: string = decodeURIComponent(pairs[i].substring(eq + 1));
    out[k] = v;
  }
  return out;
}

/**
 * Assert every base parameter that `RequestBuilder.baseParams()` builds is
 * present and well-formed on a single recorded request. Catches regressions
 * where a module bypasses baseParams or accidentally drops a required field.
 * Does NOT validate feature-specific params — those are tested per-feature.
 *
 * Validations:
 *   - `app_key`, `device_id`, `sdk_name`, `sdk_version`, `av` non-empty.
 *   - `t` is one of `'0'` (developer), `'1'` (SDK-generated), `'3'` (temp).
 *   - `timestamp` parses as a number > 0.
 *   - `hour` parses as 0..23, `dow` as 0..6.
 *   - `tz` parses as a finite number (signed offset in minutes).
 */
export function assertValidBaseParams(call: RecordedCall): void {
  const p: Record<string, string> = parseQueryParams(call.data);
  expect(p['app_key'] !== undefined && p['app_key'].length > 0).assertTrue();
  expect(p['device_id'] !== undefined && p['device_id'].length > 0).assertTrue();
  expect(p['sdk_name'] !== undefined && p['sdk_name'].length > 0).assertTrue();
  expect(p['sdk_version'] !== undefined && p['sdk_version'].length > 0).assertTrue();
  expect(p['av'] !== undefined && p['av'].length > 0).assertTrue();
  expect(p['t'] === '0' || p['t'] === '1' || p['t'] === '3').assertTrue();
  const ts: number = parseInt(p['timestamp'], 10);
  expect(ts > 0).assertTrue();
  const hour: number = parseInt(p['hour'], 10);
  expect(hour >= 0 && hour <= 23).assertTrue();
  const dow: number = parseInt(p['dow'], 10);
  expect(dow >= 0 && dow <= 6).assertTrue();
  const tz: number = parseInt(p['tz'], 10);
  expect(!isNaN(tz)).assertTrue();
}

/**
 * Assert that a sequence of substring keys appears in `calls` in the given
 * relative order. Each key must appear at least once; the first occurrence
 * of `keys[i]` must come strictly before the first occurrence of `keys[i+1]`.
 *
 * Use this to lock in wire-order invariants like
 * "consent ships before begin_session" without coupling the test to other
 * unrelated requests that may appear between or around the keys.
 *
 * Throws via `expect().assertTrue()` if any key is missing or out of order,
 * so a failure surfaces with the line that called this helper.
 */
export function assertWireOrder(calls: RecordedCall[], keys: string[]): void {
  let cursor: number = -1;
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    let found: number = -1;
    for (let j = cursor + 1; j < calls.length; j++) {
      if (calls[j].data.indexOf(key) !== -1) {
        found = j;
        break;
      }
    }
    // Either the key is missing entirely or it appears at/before the cursor —
    // both are order violations.
    expect(found > cursor).assertTrue();
    cursor = found;
  }
}
