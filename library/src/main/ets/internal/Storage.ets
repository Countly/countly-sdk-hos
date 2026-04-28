import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import { Logger } from './Logger';

/**
 * Per-instance persistent storage. Each Countly instance (identified by its
 * appKey) gets its own preferences file; this is what gives us multi-instance
 * storage isolation as required by the dev guide.
 *
 * Tests substitute storage by passing a `storageOverride` to
 * `Countly.initShared` / `createInstance`, avoiding the need for a real
 * HarmonyOS Context or preferences file.
 *
 * Keys used:
 *   cly_device_id        — stored device ID (survives app restart)
 *   cly_device_id_type   — "DEVELOPER_SUPPLIED" | "SDK_GENERATED" | "TEMPORARY_ID"
 *   cly_request_queue    — delimiter-joined serialized query strings
 *   cly_sbs              — SDK Behavior Settings JSON
 *   cly_remote_config    — Remote Config cache JSON
 *   cly_push_token       — most recently sent push token (for resend on
 *                          device-id change / consent grant)
 *   cly_push_provider    — paired provider name ("HMS" | "FCM" | "APN")
 */
export class Storage {
  protected static readonly REQUEST_DELIMITER: string = ':::';
  protected prefs: preferences.Preferences | null = null;
  protected logger: Logger;
  protected fileName: string;

  constructor(logger: Logger, appKey: string) {
    this.logger = logger;
    // Sanitized-alone used to collide for distinct appKeys ("abc-def" and
    // "abc_def" both → "abc_def"). Appending a short hash of the raw appKey
    // disambiguates without a fully hash-only filename (which would hurt
    // debuggability for the common well-formed case).
    const sanitized: string = Storage.sanitize(appKey);
    const disambiguator: string = Storage.shortDigest(appKey);
    this.fileName = `countly_${sanitized}_${disambiguator}`;
  }

  protected static sanitize(key: string): string {
    return key.replace(/[^A-Za-z0-9_]/g, '_');
  }

  /**
   * A tiny, non-cryptographic digest of the raw appKey. Used only to
   * disambiguate two appKeys that sanitize to the same sequence — it does
   * NOT need to resist collisions at cryptographic strength, and keeping it
   * short keeps filenames readable. 32-bit FNV-1a base36 → <= 7 chars.
   */
  protected static shortDigest(input: string): string {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < input.length; i++) {
      hash ^= input.charCodeAt(i);
      // Multiply by FNV prime 16777619, truncated to 32-bit via `| 0`.
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) | 0;
    }
    return (hash >>> 0).toString(36);
  }

  public async init(context: common.Context): Promise<boolean> {
    try {
      this.prefs = await preferences.getPreferences(context, this.fileName);
      return true;
    } catch (err) {
      // prefs stays null; callers should branch on the return, not just
      // assume init succeeded. Every subsequent set/get is a soft no-op.
      this.logger.e(`[Storage] init, failed to open preferences '${this.fileName}': ${err}`);
      return false;
    }
  }

  public async getString(key: string, fallback: string): Promise<string> {
    if (!this.prefs) return fallback;
    try {
      const value: preferences.ValueType = await this.prefs.get(key, fallback);
      return typeof value === 'string' ? value : fallback;
    } catch (err) {
      this.logger.e(`[Storage] getString, ${key}: ${err}`);
      return fallback;
    }
  }

  /**
   * Returns true on successful persist, false on failure (e.g. preferences not
   * initialized, disk full, etc.). Callers use the return to decide whether to
   * trust the in-memory queue as authoritative.
   */
  public async setString(key: string, value: string): Promise<boolean> {
    if (!this.prefs) {
      this.logger.w(`[Storage] setString, preferences not initialized; '${key}' not persisted`);
      return false;
    }
    try {
      await this.prefs.put(key, value);
      await this.prefs.flush();
      return true;
    } catch (err) {
      this.logger.e(`[Storage] setString, ${key}: ${err}`);
      return false;
    }
  }

  public async remove(key: string): Promise<boolean> {
    if (!this.prefs) return false;
    try {
      await this.prefs.delete(key);
      await this.prefs.flush();
      return true;
    } catch (err) {
      this.logger.e(`[Storage] remove, ${key}: ${err}`);
      return false;
    }
  }

  public async loadRequestQueue(): Promise<string[]> {
    const raw: string = await this.getString('cly_request_queue', '');
    if (raw.length === 0) return [];
    const parts: string[] = raw.split(Storage.REQUEST_DELIMITER);
    // Every stored request is a URL-encoded query string; a valid entry must
    // contain at least one `key=` pair. Filter corrupt fragments (e.g. a crash
    // or concurrent write that partially truncated the file) with a loud log
    // so the silent "half-batch" behavior doesn't hide data loss.
    const kept: string[] = [];
    let dropped: number = 0;
    for (let i = 0; i < parts.length; i++) {
      if (/^[A-Za-z0-9_%]+=/.test(parts[i])) {
        kept.push(parts[i]);
      } else {
        dropped++;
      }
    }
    if (dropped > 0) {
      this.logger.w(`[Storage] loadRequestQueue, dropped ${dropped} corrupt/empty queue fragment(s)`);
    }
    return kept;
  }

  public async saveRequestQueue(queue: string[]): Promise<boolean> {
    return await this.setString('cly_request_queue', queue.join(Storage.REQUEST_DELIMITER));
  }
}

