import { Logger } from '../internal/Logger';
import { ModuleDeviceId } from '../internal/modules/ModuleDeviceId';
import { DeviceIdType } from '../types/Types';

/** User-facing device-id surface — accessed via `Countly.sharedInstance().deviceId`. */
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
  public isTemporaryIdMode(): boolean { return this.module.isTemporary(); }

  public async enableTemporaryIdMode(): Promise<void> {
    this.logger.i('[DeviceId] Calling enableTemporaryIdMode');
    await this.module.enableTemporaryIdMode();
  }
}
