import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { DeviceIdType } from '../../types/Types';
import { TEMP_DEVICE_ID } from '../RequestQueue';

const KEY_DEVICE_ID: string = 'cly_device_id';
const KEY_DEVICE_ID_TYPE: string = 'cly_device_id_type';
const KEY_ID_BEFORE_OFFLINE: string = 'cly_device_id_before_offline';
const KEY_TYPE_BEFORE_OFFLINE: string = 'cly_device_id_type_before_offline';

/** Reacts to a device ID change once the new ID is stored. `merged` is true when the user's state continues. */
export type DeviceIdChangeListener = (oldId: string, newId: string, merged: boolean) => Promise<void>;

/** Runs under the old ID, before a change without merge stores the new one. */
export type BeforeNonMergedSwapHook = (oldId: string, newId: string) => Promise<void>;

/**
 * Owns the current device ID and its type. Everything that needs to know
 * "who is this user?" asks us, including the RequestBuilder via a callback
 * closure. We also drive the tricky initialization matrix described in the
 * dev guide's "Device ID State Management" section.
 *
 * Offline mode is the TEMPORARY_ID type: data is recorded under the
 * placeholder ID and the request queue holds it until a real ID replaces
 * the placeholder.
 */
export class ModuleDeviceId extends ModuleBase {
  private core: SdkCore;
  private currentId: string = '';
  private currentType: DeviceIdType = DeviceIdType.SDK_GENERATED;
  private onChange: DeviceIdChangeListener | null = null;
  private onBeforeNonMergedSwap: BeforeNonMergedSwapHook | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleDeviceId] Initialising');
    this.core = core;
  }

  /** Sets the listener that every device ID change notifies once the new ID is stored. */
  public setChangeListener(cb: DeviceIdChangeListener): void {
    this.onChange = cb;
  }

  /**
   * Pre-swap hook for the changeWithoutMerge path. Fires UNDER THE OLD ID,
   * after events/UP have flushed but before commit(). Used by CountlyInstance
   * to emit end_session (non-manual + active session) and consent-reset
   * requests under the old identity before the device-id swap.
   */
  public setBeforeNonMergedSwapHook(cb: BeforeNonMergedSwapHook): void {
    this.onBeforeNonMergedSwap = cb;
  }

  public async resolveInitial(): Promise<void> {
    const storage = this.config.storage;
    if (!storage) {
      // No storage → no persistence. Generate an ephemeral id so the instance
      // can still function; every restart will look like a new user. Log at
      // ERROR so the integrator sees this, it only happens if init() failed
      // and storage is null, which should already have been logged there.
      this.config.logger.e('[ModuleDeviceId] resolveInitial, no storage, generating ephemeral id');
      this.currentId = Utils.generateUUID();
      this.currentType = DeviceIdType.SDK_GENERATED;
      return;
    }
    const storedId: string = await storage.getString(KEY_DEVICE_ID, '');
    const storedType: string = await storage.getString(KEY_DEVICE_ID_TYPE, '');
    const custom: string | null = this.config.customDeviceId;
    const customIsPlaceholder: boolean = custom === TEMP_DEVICE_ID;
    const clear: boolean = this.config.clearStoredDeviceId;
    const storedIsOffline: boolean = storedType === DeviceIdType.TEMPORARY_ID;
    const storedIsReal: boolean = storedId.length > 0 && !storedIsOffline;

    if (clear && storedId.length > 0) {
      await storage.remove(KEY_DEVICE_ID);
      await storage.remove(KEY_DEVICE_ID_TYPE);
      await this.forgetIdBeforeOfflineMode();
      this.config.logger.i('[ModuleDeviceId] resolveInitial, cleared stored device id');
    }

    // Dev guide order: a stored real ID, then the ID in the config, then
    // offline mode (from the config, or still active from the previous run
    // unless the clear flag is set), then a generated ID.
    if (storedIsReal && !clear) {
      // Explicitly match both real types so a corrupt/unknown stored type is
      // logged loudly instead of silently being reclassified as
      // SDK_GENERATED (which would pick the wrong merge path on a later
      // setID and collapse two users' data on the server).
      let type: DeviceIdType;
      if (storedType === DeviceIdType.DEVELOPER_SUPPLIED) {
        type = DeviceIdType.DEVELOPER_SUPPLIED;
      } else if (storedType === DeviceIdType.SDK_GENERATED) {
        type = DeviceIdType.SDK_GENERATED;
      } else {
        this.config.logger.e(`[ModuleDeviceId] resolveInitial, unknown stored type '${storedType}', defaulting to SDK_GENERATED`);
        type = DeviceIdType.SDK_GENERATED;
      }
      this.currentId = storedId;
      this.currentType = type;
    } else if (custom !== null && custom.length > 0 && !customIsPlaceholder) {
      await this.commit(custom, DeviceIdType.DEVELOPER_SUPPLIED);
    } else if (this.config.startInOfflineMode || customIsPlaceholder || (storedIsOffline && !clear)) {
      await this.commit(TEMP_DEVICE_ID, DeviceIdType.TEMPORARY_ID);
    } else {
      await this.commit(Utils.generateUUID(), DeviceIdType.SDK_GENERATED);
    }

    // Requests queued under the placeholder are sent under the real ID, and wait while offline mode continues.
    if (!this.isTemporary()) {
      await this.forgetIdBeforeOfflineMode();
      await this.core.requestQueue.replaceTempDeviceId(this.currentId);
    }
  }

  public getId(): string { return this.currentId; }
  public getType(): DeviceIdType { return this.currentType; }
  /** Whether the SDK is in offline mode, which uses the placeholder ID with the TEMPORARY_ID type. */
  public isTemporary(): boolean { return this.currentType === DeviceIdType.TEMPORARY_ID; }

  /**
   * setID picks merge vs non-merge based on the current type, this is the
   * method most integrators should use. The specialized change* methods are
   * advanced-only.
   */
  public async setID(newId: string): Promise<void> {
    if (this.rejectIfHalted('ModuleDeviceId', 'setID')) return;
    if (Utils.isNullOrEmpty(newId)) {
      this.config.logger.w('[ModuleDeviceId] setID, null/empty ignored');
      this.config.logger.healthCode('w601');
      return;
    }
    if (newId === this.currentId) {
      this.config.logger.d('[ModuleDeviceId] setID, same id, ignored');
      return;
    }
    // A developer-supplied ID is a user switch, so no merge; an SDK-generated
    // one is merged into the new user. In offline mode both change methods
    // only leave offline mode with the new ID.
    if (this.currentType === DeviceIdType.DEVELOPER_SUPPLIED || this.isTemporary()) {
      await this.changeWithoutMerge(newId);
    } else {
      await this.changeWithMerge(newId);
    }
  }

  public async changeWithoutMerge(newId: string): Promise<void> {
    if (this.rejectIfHalted('ModuleDeviceId', 'changeWithoutMerge')) return;
    if (Utils.isNullOrEmpty(newId)) return;
    if (newId === this.currentId) return;
    if (newId === TEMP_DEVICE_ID) {
      await this.enterOfflineMode();
      return;
    }
    if (this.isTemporary()) {
      await this.leaveOfflineMode(newId, DeviceIdType.DEVELOPER_SUPPLIED);
      return;
    }
    await this.changeWithoutMergeInternal(newId, DeviceIdType.DEVELOPER_SUPPLIED);
  }

  public async changeWithMerge(newId: string): Promise<void> {
    if (this.rejectIfHalted('ModuleDeviceId', 'changeWithMerge')) return;
    if (Utils.isNullOrEmpty(newId)) return;
    if (newId === this.currentId) return;
    if (newId === TEMP_DEVICE_ID) {
      await this.enterOfflineMode();
      return;
    }
    if (this.isTemporary()) {
      await this.leaveOfflineMode(newId, DeviceIdType.DEVELOPER_SUPPLIED);
      return;
    }
    const oldId: string = this.currentId;
    // Flush pending user-profile changes BEFORE the id switch so the merge
    // server-side has both halves of the user's data tied to ids it can
    // resolve. Without this, profile changes recorded since the last save
    // would land on the NEW id and the merge would orphan them.
    await this.core.saveUserProfileIfPending();
    await this.commit(newId, DeviceIdType.DEVELOPER_SUPPLIED);

    // Merge request goes through the normal queue using the new ID, with
    // an "old_device_id" parameter so the server can merge the profiles.
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['old_device_id'] = oldId;
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
    await this.notifyChange(oldId, newId, true);
  }

  /**
   * Enters offline mode at runtime. It works like a change without merge to
   * the placeholder ID: the pending data goes out under the current ID, the
   * session ends and consent is removed. The current ID and type are kept
   * for `disableOfflineMode()`.
   */
  public async enableOfflineMode(): Promise<void> {
    if (this.rejectIfHalted('ModuleDeviceId', 'enableOfflineMode')) return;
    await this.enterOfflineMode();
  }

  /**
   * Leaves offline mode. With a device ID it works like setID in offline
   * mode, and the ID is DEVELOPER_SUPPLIED. Without one the SDK returns to
   * the device ID and type it had before offline mode, or generates an ID
   * when offline mode started at init. Ignored with a warning outside
   * offline mode.
   */
  public async disableOfflineMode(deviceId: string | null): Promise<void> {
    if (this.rejectIfHalted('ModuleDeviceId', 'disableOfflineMode')) return;
    if (!this.isTemporary()) {
      this.config.logger.w('[ModuleDeviceId] disableOfflineMode, not in offline mode, ignored');
      return;
    }
    if (deviceId !== null && deviceId.length > 0) {
      if (deviceId === TEMP_DEVICE_ID) {
        this.config.logger.w('[ModuleDeviceId] disableOfflineMode, the placeholder is not a device ID, ignored');
        this.config.logger.healthCode('w601');
        return;
      }
      await this.leaveOfflineMode(deviceId, DeviceIdType.DEVELOPER_SUPPLIED);
      return;
    }
    const storage = this.config.storage;
    const previousId: string = storage ? await storage.getString(KEY_ID_BEFORE_OFFLINE, '') : '';
    const previousType: string = storage ? await storage.getString(KEY_TYPE_BEFORE_OFFLINE, '') : '';
    if (previousId.length > 0 && previousType === DeviceIdType.DEVELOPER_SUPPLIED) {
      await this.leaveOfflineMode(previousId, DeviceIdType.DEVELOPER_SUPPLIED);
    } else if (previousId.length > 0 && previousType === DeviceIdType.SDK_GENERATED) {
      await this.leaveOfflineMode(previousId, DeviceIdType.SDK_GENERATED);
    } else {
      await this.leaveOfflineMode(Utils.generateUUID(), DeviceIdType.SDK_GENERATED);
    }
  }

  /** Enters offline mode, unless the SDK is already in it. */
  private async enterOfflineMode(): Promise<void> {
    if (this.isTemporary()) {
      this.config.logger.d('[ModuleDeviceId] enableOfflineMode, already in offline mode, ignored');
      return;
    }
    await this.rememberIdBeforeOfflineMode();
    await this.changeWithoutMergeInternal(TEMP_DEVICE_ID, DeviceIdType.TEMPORARY_ID);
  }

  /**
   * Leaves offline mode with the given ID. The server never saw the
   * placeholder, so nothing is merged and nothing is reset: the queued
   * requests move to the new ID, and the change is reported as one that
   * keeps the user's state.
   */
  private async leaveOfflineMode(newId: string, type: DeviceIdType): Promise<void> {
    const oldId: string = this.currentId;
    await this.commit(newId, type);
    await this.forgetIdBeforeOfflineMode();
    await this.core.requestQueue.replaceTempDeviceId(newId);
    await this.notifyChange(oldId, newId, true);
  }

  /**
   * A change without merge, a user switch: the pending data goes out under
   * the old ID, the pre-swap hook ends the session and removes consent, then
   * the new ID is stored and the modules reset for the new user.
   */
  private async changeWithoutMergeInternal(newId: string, type: DeviceIdType): Promise<void> {
    const oldId: string = this.currentId;
    // Wire order under the OLD id:
    //   1. flush buffered events
    //   2. save pending user-profile changes
    //   3. (CountlyInstance hook) end_session + consent-reset
    //   4. swap the id (commit)
    // baseParams() returns the OLD id until commit() runs, so every request
    // built in 1 to 3 carries the old device_id. Steps 1 and 2 are gated internally
    // (events queue empty, UP not dirty) so they no-op when there's nothing
    // to ship.
    await this.core.flushEvents();
    await this.core.saveUserProfileIfPending();
    const beforeSwap: BeforeNonMergedSwapHook | null = this.onBeforeNonMergedSwap;
    if (beforeSwap !== null) await beforeSwap(oldId, newId);
    await this.commit(newId, type);
    await this.notifyChange(oldId, newId, false);
  }

  /** Runs the change listener, if one is set. */
  private async notifyChange(oldId: string, newId: string, merged: boolean): Promise<void> {
    const listener: DeviceIdChangeListener | null = this.onChange;
    if (listener !== null) await listener(oldId, newId, merged);
  }

  /** Keeps the current device ID and type for `disableOfflineMode()`. */
  private async rememberIdBeforeOfflineMode(): Promise<void> {
    const storage = this.config.storage;
    if (!storage) return;
    await storage.setString(KEY_ID_BEFORE_OFFLINE, this.currentId);
    await storage.setString(KEY_TYPE_BEFORE_OFFLINE, this.currentType);
  }

  /** Forgets the device ID kept for `disableOfflineMode()`, once offline mode has ended. */
  private async forgetIdBeforeOfflineMode(): Promise<void> {
    const storage = this.config.storage;
    if (!storage) return;
    const kept: string = await storage.getString(KEY_ID_BEFORE_OFFLINE, '');
    if (kept.length === 0) return;
    await storage.remove(KEY_ID_BEFORE_OFFLINE);
    await storage.remove(KEY_TYPE_BEFORE_OFFLINE);
  }

  private async commit(id: string, type: DeviceIdType): Promise<void> {
    this.currentId = id;
    this.currentType = type;
    const storage = this.config.storage!;
    const okId: boolean = await storage.setString(KEY_DEVICE_ID, id);
    const okType: boolean = await storage.setString(KEY_DEVICE_ID_TYPE, type);
    if (!okId || !okType) {
      // Persist failure is loud: the in-memory ID is ahead of disk, so the
      // next cold start will see the old (or empty) stored ID and split the
      // user into two server-side identities. No way to recover silently.
      this.config.logger.e(
        `[ModuleDeviceId] commit, failed to persist (okId=${okId} okType=${okType}), device id will regenerate on next launch`
      );
    }
  }
}
