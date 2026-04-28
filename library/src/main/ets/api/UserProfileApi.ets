import { Logger } from '../internal/Logger';
import { ModuleUserProfile } from '../internal/modules/ModuleUserProfile';
import { SegmentationMap, SegmentationValue } from '../types/Types';

/**
 * User-facing user-profile surface — accessed via
 * `Countly.sharedInstance().userProfile`.
 */
export class UserProfileApi {
  private readonly logger: Logger;
  private readonly module: ModuleUserProfile;

  constructor(logger: Logger, module: ModuleUserProfile) {
    this.logger = logger;
    this.module = module;
  }

  public setProperty(key: string, value: SegmentationValue): void {
    this.logger.i(`[UserProfile] Calling setProperty, key=[${key}]`);
    this.module.setProperty(key, value);
  }

  public setProperties(data: SegmentationMap): void {
    this.logger.i('[UserProfile] Calling setProperties');
    this.module.setProperties(data);
  }

  public increment(key: string): void {
    this.logger.i(`[UserProfile] Calling increment, key=[${key}]`);
    this.module.increment(key);
  }

  public incrementBy(key: string, value: number): void {
    this.logger.i(`[UserProfile] Calling incrementBy, key=[${key}] value=[${value}]`);
    this.module.incrementBy(key, value);
  }

  public multiply(key: string, value: number): void {
    this.logger.i(`[UserProfile] Calling multiply, key=[${key}] value=[${value}]`);
    this.module.multiply(key, value);
  }

  public saveMax(key: string, value: number): void {
    this.logger.i(`[UserProfile] Calling saveMax, key=[${key}] value=[${value}]`);
    this.module.saveMax(key, value);
  }

  public saveMin(key: string, value: number): void {
    this.logger.i(`[UserProfile] Calling saveMin, key=[${key}] value=[${value}]`);
    this.module.saveMin(key, value);
  }

  public setOnce(key: string, value: string): void {
    this.logger.i(`[UserProfile] Calling setOnce, key=[${key}]`);
    this.module.setOnce(key, value);
  }

  public push(key: string, value: string): void {
    this.logger.i(`[UserProfile] Calling push, key=[${key}]`);
    this.module.push(key, value);
  }

  public pushUnique(key: string, value: string): void {
    this.logger.i(`[UserProfile] Calling pushUnique, key=[${key}]`);
    this.module.pushUnique(key, value);
  }

  public pull(key: string, value: string): void {
    this.logger.i(`[UserProfile] Calling pull, key=[${key}]`);
    this.module.pull(key, value);
  }

  public async save(): Promise<void> {
    this.logger.i('[UserProfile] Calling save');
    await this.module.save();
  }

  public clear(): void {
    this.logger.i('[UserProfile] Calling clear');
    this.module.clear();
  }
}
