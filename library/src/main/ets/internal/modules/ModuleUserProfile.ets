import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { ListingFilters } from '../ServerConfig';
import { CountlyFeature, SegmentationMap, SegmentationValue } from '../../types/Types';

const PREDEFINED_KEYS: string[] = ['name', 'username', 'email', 'organization', 'phone', 'picture', 'gender', 'byear'];
const PICTURE_MAX_LEN: number = 4096;

/**
 * Buffered user-profile edits. Predefined fields go at the JSON top level;
 * everything else is nested under "custom". Modifier ops ($inc, $push, ...)
 * accumulate per-key so multiple push() calls become one array.
 *
 * Mutation methods (setProperty / setProperties / modifiers / clear)
 * auto-trigger an EVENTS-ONLY flush when the events queue is non-empty.
 * They do NOT enqueue `user_details`;
 * that ships only on explicit `save()` or a save-triggering callsite
 * (recordEvent prelude, begin/update/end session, heartbeat tick,
 * device-id change). With no events buffered the auto-trigger no-ops.
 *
 * Triggers serialize through `this.chain` so a burst of synchronous calls
 * (e.g. `setProperty('a','1'); setProperty('a','2'); ...`) coalesces into
 * one request reading the latest buffer state. The first chain entry in a
 * burst writes the merged final state and clears `pending` synchronously
 * before awaiting `enqueue`; later entries see `pending=false` and bail.
 */
export class ModuleUserProfile extends ModuleBase {
  private core: SdkCore;
  private predefined: Record<string, SegmentationValue> = {};
  private customSet: Record<string, SegmentationValue> = {};
  private modifiers: Record<string, Record<string, SegmentationValue | string[] | number[]>> = {};
  private pending: boolean = false;
  private chain: Promise<void> = Promise.resolve();

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleUserProfile] Initialising');
    this.core = core;
  }

  public override async onInit(): Promise<void> {
    // Apply initial user properties HERE, not in the constructor. Defer so
    // ModuleConsent exists (its ctor runs later in CountlyInstance) and so
    // `limits` has been populated from any SBS response. `save()` at the
    // first request-enqueue checkpoint will still consent-gate the payload.
    const keys: string[] = Object.keys(this.config.initialUserProperties);
    if (keys.length > 0) {
      this.setProperties(this.config.initialUserProperties);
    }
  }

  public hasPendingChanges(): boolean { return this.pending; }

  public setProperty(key: string, value: SegmentationValue): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'setProperty')) return;
    if (Utils.isNullOrEmpty(key)) {
      this.config.logger.w('[ModuleUserProfile] setProperty, empty key, ignored');
      return;
    }
    const one: SegmentationMap = {};
    one[key] = value;
    this.setProperties(one);
  }

  public setProperties(data: SegmentationMap): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'setProperties')) return;
    const keys: string[] = Object.keys(data);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const value: SegmentationValue = data[key];
      if (value === null || value === undefined) {
        this.config.logger.w(`[ModuleUserProfile] setProperties, null value for '${key}', ignored`);
        continue;
      }
      // SDK Behavior Settings user-property filter (upb/upw). Predefined
      // keys ride through unfiltered, they're SDK-owned and dashboards
      // depend on `name` / `email` / etc. always being present.
      if (PREDEFINED_KEYS.indexOf(key) === -1
          && !ListingFilters.applyUserPropertyFilter(key, this.config.serverConfig)) {
        this.config.logger.d(`[ModuleUserProfile] setProperties, '${key}' filtered out by user-property filter, ignored`);
        continue;
      }
      if (PREDEFINED_KEYS.indexOf(key) !== -1) {
        if (typeof value === 'string') {
          const maxLen: number = key === 'picture' ? PICTURE_MAX_LEN : this.config.limits.maxValueSize;
          this.predefined[key] = value.length === 0 ? '' : Utils.truncate(value, maxLen);
        } else {
          this.predefined[key] = value;
        }
      } else {
        const truncatedKey: string = Utils.truncate(key, this.config.limits.maxKeyLength);
        if (typeof value === 'string') {
          this.customSet[truncatedKey] = Utils.truncate(value, this.config.limits.maxValueSize);
        } else {
          this.customSet[truncatedKey] = value;
        }
      }
      this.pending = true;
    }
    this.applyCustomCacheLimit();
    this.scheduleAutoSave();
  }

  public increment(key: string): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'increment')) return;
    this.addModifier('$inc', key, 1);
  }
  public incrementBy(key: string, value: number): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'incrementBy')) return;
    this.addModifier('$inc', key, value);
  }
  public multiply(key: string, value: number): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'multiply')) return;
    this.addModifier('$mul', key, value);
  }
  public saveMax(key: string, value: number): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'saveMax')) return;
    this.addModifier('$max', key, value);
  }
  public saveMin(key: string, value: number): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'saveMin')) return;
    this.addModifier('$min', key, value);
  }
  public setOnce(key: string, value: string): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'setOnce')) return;
    this.addModifier('$setOnce', key, Utils.truncate(value, this.config.limits.maxValueSize));
  }
  public push(key: string, value: string): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'push')) return;
    this.appendModifierArray('$push', key, Utils.truncate(value, this.config.limits.maxValueSize));
  }
  public pushUnique(key: string, value: string): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'pushUnique')) return;
    this.appendModifierArray('$addToSet', key, Utils.truncate(value, this.config.limits.maxValueSize));
  }
  public pull(key: string, value: string): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'pull')) return;
    this.appendModifierArray('$pull', key, Utils.truncate(value, this.config.limits.maxValueSize));
  }

  /**
   * Public save entry, UNCONDITIONAL. Queues an unconditional task on the
   * chain so the explicit caller's "save now" intent isn't gated on the
   * events queue. Still goes through the chain for ordering (so a mutation
   * that fired auto-save just before doesn't double-enqueue with us).
   */
  public async save(): Promise<void> {
    if (this.rejectIfHalted('ModuleUserProfile', 'save')) return;
    await this.scheduleUnconditionalSave();
  }

  public clear(): void {
    if (this.rejectIfHalted('ModuleUserProfile', 'clear')) return;
    this.predefined = {};
    this.customSet = {};
    this.modifiers = {};
    this.pending = false;
  }

  /**
   * Mutation auto-trigger: when properties change while events are pending,
   * flush the events queue so the wire ordering puts events before any
   * later user_details. Does NOT enqueue a `user_details` request, that
   * only ships on explicit `save()` or a save-triggering callsite
   * (recordEvent prelude, begin/end session, heartbeat, device-id change).
   * With no events the task no-ops.
   */
  private scheduleAutoSave(): Promise<void> {
    const next: Promise<void> = this.chain.then((): Promise<void> => this.gatedEventsFlushOnly());
    this.chain = next.catch((err: Object): void => {
      this.config.logger.e(`[ModuleUserProfile] auto events flush failed: ${err}`);
    });
    return next;
  }

  /**
   * Explicit-save chain entry, flushes events first (so the wire orders
   * events= before user_details=) and then ships the bundled user_details.
   * Used by the public `save()` method so integrators (and
   * `saveUserProfileIfPending` callers) can land a user_details request
   * without first recording an event.
   */
  private scheduleUnconditionalSave(): Promise<void> {
    const next: Promise<void> = this.chain.then((): Promise<void> => this.flushEventsThenSave());
    this.chain = next.catch((err: Object): void => {
      this.config.logger.e(`[ModuleUserProfile] explicit save failed: ${err}`);
    });
    return next;
  }

  private async gatedEventsFlushOnly(): Promise<void> {
    if (!this.core.hasPendingEvents()) return;
    await this.core.flushEvents();
  }

  private async flushEventsThenSave(): Promise<void> {
    // Order matters: events first so any in-memory event batch lands in the
    // request queue ahead of the user_details request.
    await this.core.flushEvents();
    await this.saveInternal();
  }

  private async saveInternal(): Promise<void> {
    if (!this.pending) return;
    if (!this.core.consentModule.hasConsent(CountlyFeature.USERS)) {
      this.pending = false;
      return;
    }
    // `Record<string, Object | null>` makes the "empty string == delete me
    // == wire null" convention explicit at the type level, instead of the
    // `as unknown as Object` double-cast hole that was here before.
    const userDetails: Record<string, Object | null> = {};
    const predKeys: string[] = Object.keys(this.predefined);
    for (let i = 0; i < predKeys.length; i++) {
      const k: string = predKeys[i];
      const v: SegmentationValue = this.predefined[k];
      userDetails[k] = v === '' ? null : (v as Object);
    }
    const custom: Record<string, Object | null> = {};
    const customKeys: string[] = Object.keys(this.customSet);
    for (let i = 0; i < customKeys.length; i++) {
      const k: string = customKeys[i];
      const v: SegmentationValue = this.customSet[k];
      custom[k] = v === '' ? null : (v as Object);
    }
    const modKeys: string[] = Object.keys(this.modifiers);
    for (let i = 0; i < modKeys.length; i++) {
      const mod: string = modKeys[i];
      const entries: Record<string, SegmentationValue | string[] | number[]> = this.modifiers[mod];
      const entryKeys: string[] = Object.keys(entries);
      const entryObj: Record<string, Object> = {};
      for (let j = 0; j < entryKeys.length; j++) {
        entryObj[entryKeys[j]] = entries[entryKeys[j]] as Object;
      }
      custom[mod] = entryObj as Object;
    }
    if (Object.keys(custom).length > 0) {
      userDetails['custom'] = custom as Object | null;
    }

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['user_details'] = JSON.stringify(userDetails);
    const body: string = Utils.buildQueryString(params);

    // Clear buffer + pending SYNCHRONOUSLY before awaiting enqueue. The
    // auto-save chain serialises calls within the module, but `core.
    // saveUserProfileIfPending` (called by ModuleEvents/Sessions/DeviceId)
    // calls our public `save()` which also goes through the chain. The
    // chain promise stays open across `await enqueue`, so if a fresh
    // mutation arrives it would re-mark pending and the *next* chain
    // entry would re-enqueue the SAME data. Clearing here ensures the
    // next entry's saveInternal sees a clean slate and the new mutation
    // owns its own enqueue. Tradeoff: enqueue rejection drops the body,
    // same drop-on-failure model as ModuleEvents.flushEventQueue.
    this.predefined = {};
    this.customSet = {};
    this.modifiers = {};
    this.pending = false;

    await this.core.requestQueue.enqueue(body);
  }

  private addModifier(modName: string, key: string, value: number | string): void {
    if (Utils.isNullOrEmpty(key)) return;
    if (!ListingFilters.applyUserPropertyFilter(key, this.config.serverConfig)) {
      this.config.logger.d(`[ModuleUserProfile] addModifier, '${key}' filtered out by user-property filter, ignored`);
      return;
    }
    const truncatedKey: string = Utils.truncate(key, this.config.limits.maxKeyLength);
    if (!this.modifiers[modName]) this.modifiers[modName] = {};
    this.modifiers[modName][truncatedKey] = value;
    this.pending = true;
    this.applyCacheLimitToMods();
    this.scheduleAutoSave();
  }

  private appendModifierArray(modName: string, key: string, value: string): void {
    if (Utils.isNullOrEmpty(key)) return;
    if (!ListingFilters.applyUserPropertyFilter(key, this.config.serverConfig)) {
      this.config.logger.d(`[ModuleUserProfile] appendModifierArray, '${key}' filtered out by user-property filter, ignored`);
      return;
    }
    const truncatedKey: string = Utils.truncate(key, this.config.limits.maxKeyLength);
    if (!this.modifiers[modName]) this.modifiers[modName] = {};
    const current = this.modifiers[modName][truncatedKey];
    let arr: string[] = [];
    if (Array.isArray(current)) {
      arr = current as string[];
    } else if (current !== undefined) {
      arr = [current as string];
    }
    arr.push(value);
    this.modifiers[modName][truncatedKey] = arr;
    this.pending = true;
    this.applyCacheLimitToMods();
    this.scheduleAutoSave();
  }

  /**
   * SDK Behavior Settings `upcl` enforcement: cap distinct custom keys at
   * the server-configured `userPropertyCacheLimit`. Drops oldest
   * insertion-order keys until size ≤ limit. ArkTS strict mode bans
   * `delete record[key]`, so we rebuild a survivors-only Record and swap
   * the field reference.
   */
  private applyCustomCacheLimit(): void {
    const limit: number = this.config.serverConfig.userPropertyCacheLimit;
    const keys: string[] = Object.keys(this.customSet);
    if (keys.length <= limit) return;
    const dropCount: number = keys.length - limit;
    const rebuilt: Record<string, SegmentationValue> = {};
    for (let i = dropCount; i < keys.length; i++) {
      rebuilt[keys[i]] = this.customSet[keys[i]];
    }
    this.customSet = rebuilt;
    this.config.logger.d(`[ModuleUserProfile] applyCustomCacheLimit, dropped ${dropCount} oldest key(s) to fit upcl=${limit}`);
  }

  private applyCacheLimitToMods(): void {
    const limit: number = this.config.serverConfig.userPropertyCacheLimit;
    // Aggregate distinct keys across all modifier ops. Our shape is
    // `op → key → value`; a "distinct key" is the union of inner keys
    // across ops. Drop the oldest (insertion order across the union).
    const seen: string[] = [];
    const owners: Record<string, string[]> = {};
    const opKeys: string[] = Object.keys(this.modifiers);
    for (let i = 0; i < opKeys.length; i++) {
      const op: string = opKeys[i];
      const innerKeys: string[] = Object.keys(this.modifiers[op]);
      for (let j = 0; j < innerKeys.length; j++) {
        const k: string = innerKeys[j];
        if (seen.indexOf(k) === -1) {
          seen.push(k);
          owners[k] = [op];
        } else {
          owners[k].push(op);
        }
      }
    }
    if (seen.length <= limit) return;
    const dropCount: number = seen.length - limit;
    const rebuiltOuter: Record<string, Record<string, SegmentationValue | string[] | number[]>> = {};
    for (let i = 0; i < opKeys.length; i++) {
      rebuiltOuter[opKeys[i]] = {};
    }
    for (let i = dropCount; i < seen.length; i++) {
      const k: string = seen[i];
      const ownerOps: string[] = owners[k];
      for (let o = 0; o < ownerOps.length; o++) {
        rebuiltOuter[ownerOps[o]][k] = this.modifiers[ownerOps[o]][k];
      }
    }
    // Drop ops that ended up empty after the prune so callers' `Object.keys(modifiers)`
    // stays meaningful.
    const finalOuter: Record<string, Record<string, SegmentationValue | string[] | number[]>> = {};
    const rebuiltOps: string[] = Object.keys(rebuiltOuter);
    for (let i = 0; i < rebuiltOps.length; i++) {
      if (Object.keys(rebuiltOuter[rebuiltOps[i]]).length > 0) {
        finalOuter[rebuiltOps[i]] = rebuiltOuter[rebuiltOps[i]];
      }
    }
    this.config.logger.d(`[ModuleUserProfile] applyCacheLimitToMods, dropped ${dropCount} oldest key(s) to fit upcl=${limit}`);
    this.modifiers = finalOuter;
  }

}
