import { CountlyConfig } from './CountlyConfig';
import { CountlyInstance } from './CountlyInstance';
import { Storage } from './internal/Storage';
import { Network } from './internal/Network';

/**
 * Process-wide entrypoint. Manages a default singleton (`sharedInstance`)
 * plus any number of named sub-instances. Multi-instance was explicitly
 * requested, each instance has its own storage, device ID, queues, AND
 * its own HarmonyOS `applicationStateChange` subscription (wired by
 * `CountlyInstance.init()` via `internal/LifecycleObserver`).
 *
 * The `lifecycle*All` statics below remain available for tests and for
 * integrators who want to drive lifecycle manually, they ignore the
 * auto-subscription path entirely and just iterate the active instances.
 */
export class Countly {
  private static shared: CountlyInstance | null = null;
  private static namedInstances: Map<string, CountlyInstance> = new Map();

  /**
   * Returns the default shared instance, creating one if it doesn't exist.
   *
   * If a shared instance already exists AND is still usable (not stopped,
   * not halted, not locked post-UCM-revoke), returns it unchanged, this
   * keeps initShared idempotent in the common case where an integrator
   * calls it from multiple entry points without keeping a reference.
   *
   * If the existing shared instance has been **stopped** / **halted** /
   * **locked by a UCM-revoke**, this method **replaces** it: stops the
   * existing instance (preserving storage, `stop()`, not `halt()`),
   * nulls the static handle, then constructs a brand-new
   * `CountlyInstance` with the supplied config and runs `init()`. The
   * persisted request queue survives the swap and drains into the new
   * instance.
   *
   * This is the single-call API for in-process re-init: after a UCM
   * revoke locks runtime consent, just call `Countly.initShared(newCfg)`
   * again to get a fresh instance with the new config. Named instances
   * (created via `createInstance`) are NOT touched.
   */
  public static async initShared(config: CountlyConfig, storageOverride?: Storage, networkOverride?: Network): Promise<CountlyInstance> {
    if (Countly.shared) {
      const existing: CountlyInstance = Countly.shared;
      const needsReplace: boolean = existing.config.halted || existing.config.consentLockedPostUnknown;
      if (!needsReplace) return existing;
      // The existing shared is unusable for further work. Stop it (preserving
      // any persisted storage) and clear the static handle so the next block
      // builds a fresh instance. stop() is idempotent, safe if the instance
      // was already halted by an integrator's manual call.
      await existing.stop();
      Countly.shared = null;
    }
    const instance: CountlyInstance = new CountlyInstance(config, storageOverride, networkOverride);
    await instance.init();
    Countly.shared = instance;
    return instance;
  }

  /** Throws if initShared() hasn't run. */
  public static sharedInstance(): CountlyInstance {
    if (!Countly.shared) {
      throw new Error('[Countly] sharedInstance called before initShared');
    }
    return Countly.shared;
  }

  /** Creates (or returns) a named instance. Instance name is separate from app key. */
  public static async createInstance(
    name: string,
    config: CountlyConfig,
    storageOverride?: Storage,
    networkOverride?: Network
  ): Promise<CountlyInstance> {
    const existing: CountlyInstance | undefined = Countly.namedInstances.get(name);
    if (existing) return existing;
    const instance: CountlyInstance = new CountlyInstance(config, storageOverride, networkOverride);
    // Tag every log line from this instance with `[Countly:<name>]` so a
    // concurrent shared + named instance pair is distinguishable in the
    // hilog stream. Must happen BEFORE init() so init-time module logs
    // also pick up the suffix.
    instance.config.logger.setInstanceName(name);
    await instance.init();
    Countly.namedInstances.set(name, instance);
    return instance;
  }

  public static getInstance(name: string): CountlyInstance | undefined {
    return Countly.namedInstances.get(name);
  }

  public static listInstances(): string[] {
    const names: string[] = [];
    Countly.namedInstances.forEach((_instance: CountlyInstance, key: string) => {
      names.push(key);
    });
    return names;
  }

  /**
   * Manual lifecycle fan-out. Auto-tracking covers the typical case via
   * each instance's own ApplicationContext subscription, but tests (and
   * integrators with non-standard ability hosts) can still drive it.
   */
  public static lifecycleForegroundAll(): void {
    if (Countly.shared) Countly.shared.lifecycleForeground();
    Countly.namedInstances.forEach((instance: CountlyInstance) => instance.lifecycleForeground());
  }

  public static lifecycleBackgroundAll(): void {
    if (Countly.shared) Countly.shared.lifecycleBackground();
    Countly.namedInstances.forEach((instance: CountlyInstance) => instance.lifecycleBackground());
  }

  /**
   * Stop every active instance (shared + every named instance) WITHOUT
   * wiping persisted storage. Equivalent to calling `instance.stop()` on
   * each, see the `stop` vs `halt` distinction on `CountlyInstance`. Use
   * this for tests / between-config swaps where you want to drop SDK
   * activity but keep buffered telemetry on disk for the next init.
   */
  public static async stopAll(): Promise<void> {
    if (Countly.shared) {
      await Countly.shared.stop();
      Countly.shared = null;
    }
    // Snapshot values into an array so a stop() that mutates the map can't
    // invalidate the iteration.
    const instances: CountlyInstance[] = [];
    Countly.namedInstances.forEach((instance: CountlyInstance) => instances.push(instance));
    for (let i = 0; i < instances.length; i++) {
      await instances[i].stop();
    }
    Countly.namedInstances.clear();
  }

  /**
   * Halt every active instance (shared + every named instance) AND wipe
   * each one's persisted storage. Equivalent to calling `instance.halt()`
   * on each. Use for "user data deletion" flows; after this completes,
   * a fresh `initShared(cfg)` starts from a clean slate (new device ID,
   * empty queue, no cached config).
   *
   * Per-instance halt failures (e.g. storage clear returns false) log a
   * warning but don't abort the loop, every instance gets its halt call.
   */
  public static async haltAll(): Promise<void> {
    if (Countly.shared) {
      await Countly.shared.halt();
      Countly.shared = null;
    }
    const instances: CountlyInstance[] = [];
    Countly.namedInstances.forEach((instance: CountlyInstance) => instances.push(instance));
    for (let i = 0; i < instances.length; i++) {
      await instances[i].halt();
    }
    Countly.namedInstances.clear();
  }
}
