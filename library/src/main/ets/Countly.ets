import { CountlyConfig } from './CountlyConfig';
import { CountlyInstance } from './CountlyInstance';
import { Storage } from './internal/Storage';
import { Network } from './internal/Network';

/**
 * Process-wide entrypoint. Manages a default singleton (`sharedInstance`)
 * plus any number of named sub-instances. Multi-instance was explicitly
 * requested — each instance has its own storage, device ID, queues, AND
 * its own HarmonyOS `applicationStateChange` subscription (wired by
 * `CountlyInstance.init()` via `internal/LifecycleObserver`).
 *
 * The `lifecycle*All` statics below remain available for tests and for
 * integrators who want to drive lifecycle manually — they ignore the
 * auto-subscription path entirely and just iterate the active instances.
 */
export class Countly {
  private static shared: CountlyInstance | null = null;
  private static namedInstances: Map<string, CountlyInstance> = new Map();

  /** Returns (and lazily initializes) the default shared instance. */
  public static async initShared(config: CountlyConfig, storageOverride?: Storage, networkOverride?: Network): Promise<CountlyInstance> {
    if (Countly.shared) return Countly.shared;
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

  public static async haltAll(): Promise<void> {
    if (Countly.shared) {
      await Countly.shared.halt();
      Countly.shared = null;
    }
    // Snapshot values into an array so a halt() that mutates the map (none
    // currently does, but be defensive) can't invalidate the iteration.
    const instances: CountlyInstance[] = [];
    Countly.namedInstances.forEach((instance: CountlyInstance) => instances.push(instance));
    for (let i = 0; i < instances.length; i++) {
      await instances[i].halt();
    }
    Countly.namedInstances.clear();
  }
}
