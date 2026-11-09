import { Logger } from '../internal/Logger';
import { ModuleDeviceId } from '../internal/modules/ModuleDeviceId';
import { DeviceIdType } from '../types/Types';

/** User-facing device-id surface, accessed via `Countly.sharedInstance().deviceId`. */
export class DeviceIdApi {
  private readonly logger: Logger;
  private readonly module: ModuleDeviceId;

  constructor(logger: Logger, module: ModuleDeviceId) {
    this.logger = logger;
    this.module = module;
  }

  public async setID(deviceId: string): Promise<void> {
    this.logger.i(`[DeviceId] Calling setID, id=[${deviceId}]`);
    await this.module.setID(deviceId);
  }

  public async changeWithoutMerge(deviceId: string): Promise<void> {
    this.logger.i(`[DeviceId] Calling changeWithoutMerge, id=[${deviceId}]`);
    await this.module.changeWithoutMerge(deviceId);
  }

  public async changeWithMerge(deviceId: string): Promise<void> {
    this.logger.i(`[DeviceId] Calling changeWithMerge, id=[${deviceId}]`);
    await this.module.changeWithMerge(deviceId);
  }

  public getID(): string { return this.module.getId(); }
  public getType(): DeviceIdType { return this.module.getType(); }

  /** Whether the SDK is in offline mode (the placeholder device ID, type TEMPORARY_ID). */
  public isOfflineMode(): boolean { return this.module.isTemporary(); }

  /**
   * Enters offline mode, for example when the user logs out: data is
   * recorded under the placeholder device ID and nothing is sent until
   * offline mode ends. Like `changeWithoutMerge`, the pending data goes out
   * under the current ID, the session ends and consent is removed.
   */
  public async enableOfflineMode(): Promise<void> {
    this.logger.i('[DeviceId] Calling enableOfflineMode');
    await this.module.enableOfflineMode();
  }

  /**
   * Leaves offline mode and sends the queued requests under the new ID. With
   * a device ID it works like `setID`; without one the SDK returns to the ID
   * it had before offline mode, or generates one. Nothing else is reset and
   * no merge request is sent.
   */
  public async disableOfflineMode(deviceId: string | null = null): Promise<void> {
    this.logger.i(`[DeviceId] Calling disableOfflineMode, deviceId=[${deviceId !== null}]`);
    await this.module.disableOfflineMode(deviceId);
  }
}
