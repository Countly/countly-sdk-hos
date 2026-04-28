import { Logger } from '../internal/Logger';
import { ModuleRemoteConfig } from '../internal/modules/ModuleRemoteConfig';
import { RCData, RCDownloadCallback } from '../types/Types';

/**
 * User-facing remote-config surface — accessed via
 * `Countly.sharedInstance().remoteConfig`. Modern `method=rc` API per dev guide
 * §4606. The legacy `method=fetch_remote_config` API is not exposed.
 */
export class RemoteConfigApi {
  private readonly logger: Logger;
  private readonly module: ModuleRemoteConfig;

  constructor(logger: Logger, module: ModuleRemoteConfig) {
    this.logger = logger;
    this.module = module;
  }

  public async downloadAllKeys(callback: RCDownloadCallback | null = null): Promise<void> {
    this.logger.i(`[RemoteConfig] Calling downloadAllKeys, callback=[${callback !== null}]`);
    await this.module.downloadAllKeys(callback);
  }

  public async downloadSpecificKeys(keysToInclude: string[], callback: RCDownloadCallback | null = null): Promise<void> {
    this.logger.i(`[RemoteConfig] Calling downloadSpecificKeys, callback=[${callback !== null}]`);
    await this.module.downloadSpecificKeys(keysToInclude, callback);
  }

  public async downloadOmittingKeys(keysToOmit: string[], callback: RCDownloadCallback | null = null): Promise<void> {
    this.logger.i(`[RemoteConfig] Calling downloadOmittingKeys, callback=[${callback !== null}]`);
    await this.module.downloadOmittingKeys(keysToOmit, callback);
  }

  public getValue(key: string): RCData | null {
    this.logger.i(`[RemoteConfig] Calling getValue, key=[${key}]`);
    return this.module.getValue(key);
  }

  public getValues(): Record<string, RCData> {
    this.logger.i('[RemoteConfig] Calling getValues');
    return this.module.getValues();
  }

  public async clearAllRemoteConfig(): Promise<void> {
    this.logger.i('[RemoteConfig] Calling clearAllRemoteConfig');
    await this.module.clearAll();
  }

  public registerDownloadCallback(cb: RCDownloadCallback): void {
    this.logger.i('[RemoteConfig] Calling registerDownloadCallback');
    this.module.registerDownloadCallback(cb);
  }

  public removeDownloadCallback(cb: RCDownloadCallback): void {
    this.logger.i('[RemoteConfig] Calling removeDownloadCallback');
    this.module.removeDownloadCallback(cb);
  }

  // A/B Testing
  public async enrollIntoABTestsForKeys(keys: string[]): Promise<void> {
    this.logger.i('[RemoteConfig] Calling enrollIntoABTestsForKeys');
    await this.module.enrollIntoABTestsForKeys(keys);
  }

  public async exitABTestsForKeys(keys: string[] | null = null): Promise<void> {
    this.logger.i('[RemoteConfig] Calling exitABTestsForKeys');
    await this.module.exitABTestsForKeys(keys);
  }

  public async getValueAndEnroll(key: string): Promise<RCData | null> {
    this.logger.i(`[RemoteConfig] Calling getValueAndEnroll, key=[${key}]`);
    return this.module.getValueAndEnroll(key);
  }

  public async getAllValuesAndEnroll(): Promise<Record<string, RCData>> {
    this.logger.i('[RemoteConfig] Calling getAllValuesAndEnroll');
    return this.module.getAllValuesAndEnroll();
  }
}
