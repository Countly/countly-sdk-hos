import common from '@ohos.app.ability.common';
import { ContentConfig, CountlyConfig, FeedbackConfig, PushConfig } from '../../../main/ets/CountlyConfig';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';
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
  return new Harness(instance, storage, network, config, instance.config.logger);
}

export async function flushTick(ms: number = 50): Promise<void> {
  await new Promise<void>((resolve: () => void) => setTimeout(() => resolve(), ms));
}
