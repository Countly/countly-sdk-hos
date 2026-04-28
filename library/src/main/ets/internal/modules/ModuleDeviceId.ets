import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { DeviceIdType } from '../../types/Types';
import { TEMP_DEVICE_ID } from '../RequestQueue';

/**
 * Owns the current device ID and its type. Everything that needs to know
 * "who is this user?" asks us — including the RequestBuilder via a callback
 * closure. We also drive the tricky initialization matrix described in the
 * dev guide's "Device ID State Management" section.
 */
export class ModuleDeviceId extends ModuleBase {
  private core: SdkCore;
  private currentId: string = '';
  private currentType: DeviceIdType = DeviceIdType.SDK_GENERATED;
  private onChange: ((oldId: string, newId: string, merged: boolean) => Promise<void>) | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleDeviceId] Initialising');
    this.core = core;
  }

  public setChangeListener(cb: (oldId: string, newId: string, merged: boolean) => Promise<void>): void {
    this.onChange = cb;
  }

  public async resolveInitial(): Promise<void> {
    const storage = this.config.storage;
    if (!storage) {
      // No storage → no persistence. Generate an ephemeral id so the instance
      // can still function; every restart will look like a new user. Log at
      // ERROR so the integrator sees this — it only happens if init() failed
      // and storage is null, which should already have been logged there.
      this.config.logger.e('[ModuleDeviceId] resolveInitial, no storage — generating ephemeral id');
      this.currentId = Utils.generateUUID();
      this.currentType = DeviceIdType.SDK_GENERATED;
      return;
    }
    const storedId: string = await storage.getString('cly_device_id', '');
    const storedType: string = await storage.getString('cly_device_id_type', '');
    const custom: string | null = this.config.customDeviceId;
    const requestTemp: boolean = this.config.startInTemporaryIdMode;
    const hasStored: boolean = storedId.length > 0;
    const storedIsTemp: boolean = storedType === DeviceIdType.TEMPORARY_ID;

    if (this.config.clearStoredDeviceId && hasStored && !storedIsTemp) {
      await storage.remove('cly_device_id');
      await storage.remove('cly_device_id_type');
      this.config.logger.i('[ModuleDeviceId] resolveInitial, cleared stored device id');
    }

    // First init OR stored was temp: honor config precedence (custom > temp request > generate)
    if (!hasStored || storedIsTemp || this.config.clearStoredDeviceId) {
      if (custom !== null && custom.length > 0) {
        await this.commit(custom, DeviceIdType.DEVELOPER_SUPPLIED);
        // If we were in temp mode, drain queued requests now that we have a real ID.
        if (storedIsTemp) await this.core.requestQueue.replaceTempDeviceId(custom);
      } else if (requestTemp) {
        await this.commit(TEMP_DEVICE_ID, DeviceIdType.TEMPORARY_ID);
      } else {
        await this.commit(Utils.generateUUID(), DeviceIdType.SDK_GENERATED);
        if (storedIsTemp) await this.core.requestQueue.replaceTempDeviceId(this.currentId);
      }
    } else {
      // Use stored, ignore provided custom/temp signals per the truth table.
      // Explicitly match all three enum values so a corrupt/unknown stored
      // type is logged loudly instead of silently being reclassified as
      // SDK_GENERATED (which would pick the wrong merge path on a later
      // setID and collapse two users' data on the server).
      let type: DeviceIdType;
      if (storedType === DeviceIdType.DEVELOPER_SUPPLIED) {
        type = DeviceIdType.DEVELOPER_SUPPLIED;
      } else if (storedType === DeviceIdType.SDK_GENERATED) {
        type = DeviceIdType.SDK_GENERATED;
      } else if (storedType === DeviceIdType.TEMPORARY_ID) {
        type = DeviceIdType.TEMPORARY_ID;
      } else {
        this.config.logger.e(`[ModuleDeviceId] resolveInitial, unknown stored type '${storedType}' — defaulting to SDK_GENERATED`);
        type = DeviceIdType.SDK_GENERATED;
      }
      this.currentId = storedId;
      this.currentType = type;
    }

    await this.core.requestQueue.cleanupOrphanedTempRequests();
  }

  public getId(): string { return this.currentId; }
  public getType(): DeviceIdType { return this.currentType; }
  public isTemporary(): boolean { return this.currentType === DeviceIdType.TEMPORARY_ID; }

  /**
   * setID picks merge vs non-merge based on the current type — this is the
   * method most integrators should use. The specialized change* methods are
   * advanced-only.
   */
  public async setID(newId: string): Promise<void> {
    if (Utils.isNullOrEmpty(newId)) {
      this.config.logger.w('[ModuleDeviceId] setID, null/empty ignored');
      return;
    }
    if (newId === this.currentId) {
      this.config.logger.d('[ModuleDeviceId] setID, same id — ignored');
      return;
    }
    // From DEV_SUPPLIED or TEMPORARY → DEV_SUPPLIED, route through
    // changeWithoutMerge: temp transitions need the queued-temp-placeholder
    // rewrite path (otherwise events recorded in temp mode never escape it
    // even after the real id arrives), and a no-merge result is what the dev
    // guide promises for "I'm telling you who I am" semantics.
    if (this.currentType === DeviceIdType.DEVELOPER_SUPPLIED || this.isTemporary()) {
      await this.changeWithoutMerge(newId);
    } else {
      await this.changeWithMerge(newId);
    }
  }

  public async changeWithoutMerge(newId: string): Promise<void> {
    if (Utils.isNullOrEmpty(newId)) return;
    if (newId === this.currentId) return;
    if (this.isTemporary() && newId === TEMP_DEVICE_ID) return;

    const oldId: string = this.currentId;
    const comingFromTemp: boolean = this.isTemporary();
    // Flush pending user-profile changes BEFORE the id switch so they attach
    // to the OLD device id (the user that accumulated them). After commit,
    // baseParams() returns the new id and any save would mis-attribute.
    await this.core.saveUserProfileIfPending();
    await this.commit(newId, DeviceIdType.DEVELOPER_SUPPLIED);

    // Drain queued temp requests now we have a real ID.
    if (comingFromTemp) {
      await this.core.requestQueue.replaceTempDeviceId(newId);
    }
    if (this.onChange) await this.onChange(oldId, newId, false);
  }

  public async changeWithMerge(newId: string): Promise<void> {
    if (Utils.isNullOrEmpty(newId)) return;
    if (newId === this.currentId) return;
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
    if (this.onChange) await this.onChange(oldId, newId, true);
  }

  public async enableTemporaryIdMode(): Promise<void> {
    if (this.isTemporary()) return;
    const oldId: string = this.currentId;
    await this.commit(TEMP_DEVICE_ID, DeviceIdType.TEMPORARY_ID);
    if (this.onChange) await this.onChange(oldId, TEMP_DEVICE_ID, false);
  }

  private async commit(id: string, type: DeviceIdType): Promise<void> {
    this.currentId = id;
    this.currentType = type;
    const storage = this.config.storage!;
    const okId: boolean = await storage.setString('cly_device_id', id);
    const okType: boolean = await storage.setString('cly_device_id_type', type);
    if (!okId || !okType) {
      // Persist failure is loud: the in-memory ID is ahead of disk, so the
      // next cold start will see the old (or empty) stored ID and split the
      // user into two server-side identities. No way to recover silently.
      this.config.logger.e(
        `[ModuleDeviceId] commit, failed to persist (okId=${okId} okType=${okType}) — device id will regenerate on next launch`
      );
    }
  }
}
