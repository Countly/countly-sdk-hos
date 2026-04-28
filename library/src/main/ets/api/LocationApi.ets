import { Logger } from '../internal/Logger';
import { ModuleLocation } from '../internal/modules/ModuleLocation';

/** User-facing location surface — accessed via `Countly.sharedInstance().location`. */
export class LocationApi {
  private readonly logger: Logger;
  private readonly module: ModuleLocation;

  constructor(logger: Logger, module: ModuleLocation) {
    this.logger = logger;
    this.module = module;
  }

  public async setLocation(country: string | null, city: string | null, gps: string | null, ip: string | null): Promise<void> {
    this.logger.i('[Location] Calling setLocation');
    await this.module.setLocation(country, city, gps, ip);
  }

  public async disableLocation(): Promise<void> {
    this.logger.i('[Location] Calling disableLocation');
    await this.module.disableLocation();
  }
}
