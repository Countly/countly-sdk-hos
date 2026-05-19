import { InternalConfig } from './InternalConfig';
import { ConsentChangeSource } from '../types/Types';

/**
 * Per-instance module lifecycle. Each module owns its feature's logic and
 * reacts to SDK-wide events emitted by the owning CountlyInstance.
 *
 * All hooks return Promise<void> so derived classes can safely override them
 * with async functions without triggering ArkTS override-signature errors.
 */
export class ModuleBase {
  protected config: InternalConfig;

  constructor(config: InternalConfig) {
    this.config = config;
  }

  /** Called once after all modules have been constructed and config is frozen. */
  public onInit(): Promise<void> { return Promise.resolve(); }

  /** Called when "foreground" transition detected (counter: 0 → 1). */
  public onEnterForeground(): void { }

  /** Called when "background" transition detected (counter: 1 → 0). */
  public onEnterBackground(): void { }

  /** Called right before consents are updated. */
  public consentWillChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    return Promise.resolve();
  }

  /** Called right after consents are updated. */
  public onConsentChanged(added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    return Promise.resolve();
  }

  /** Called on device ID change without merge, module state should be reset. */
  public onDeviceIdChangedNotMerged(oldId: string, newId: string): Promise<void> {
    return Promise.resolve();
  }

  /** Called on device ID change with merge, module state should continue. */
  public onDeviceIdChangedMerged(oldId: string, newId: string): Promise<void> {
    return Promise.resolve();
  }

  /** Called on halt/destroy of the owning instance. */
  public onHalt(): Promise<void> { return Promise.resolve(); }

  /**
   * Whether the owning instance has been halted. User-facing module mutators
   * use this to short-circuit post-halt calls. Internal methods called from
   * `onHalt` (drain paths) intentionally bypass this check.
   */
  public isHalted(): boolean { return this.config.halted; }

  /**
   * Standard guard used at the top of every user-facing module mutator. If
   * the instance is halted, logs a single WARNING line ("[ModuleX] methodY
   * called after halt, ignored") so the integrator sees why their call did
   * nothing, and returns true so the caller can early-return.
   *
   * Pattern:
   *   if (this.rejectIfHalted('ModuleEvents', 'recordEvent')) return;
   */
  protected rejectIfHalted(moduleTag: string, methodName: string): boolean {
    if (this.config.halted) {
      this.config.logger.w(`[${moduleTag}] ${methodName} called after halt, ignored`);
      return true;
    }
    return false;
  }
}
