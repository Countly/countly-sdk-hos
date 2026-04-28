import common from '@ohos.app.ability.common';
import { Logger } from '../../../../main/ets/internal/Logger';
import { Storage } from '../../../../main/ets/internal/Storage';

/**
 * Test-only in-memory Storage. Lives in the test tree so it can't be
 * accidentally wired into a production integration via the Countly facade's
 * storage override.
 */
export class InMemoryStorage extends Storage {
  private values: Map<string, string> = new Map();

  constructor(logger: Logger, appKey: string) {
    super(logger, appKey);
  }

  public override async init(_context: common.Context): Promise<boolean> {
    // Always "succeeds" in tests.
    return true;
  }

  public override async getString(key: string, fallback: string): Promise<string> {
    return this.values.has(key) ? this.values.get(key)! : fallback;
  }

  public override async setString(key: string, value: string): Promise<boolean> {
    this.values.set(key, value);
    return true;
  }

  public override async remove(key: string): Promise<boolean> {
    this.values.delete(key);
    return true;
  }

  public size(): number { return this.values.size; }

  public dump(): Record<string, string> {
    const out: Record<string, string> = {};
    this.values.forEach((v: string, k: string) => { out[k] = v; });
    return out;
  }
}
