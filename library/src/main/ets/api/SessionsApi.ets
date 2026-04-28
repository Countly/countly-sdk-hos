import { Logger } from '../internal/Logger';
import { ModuleSessions } from '../internal/modules/ModuleSessions';

/** User-facing sessions surface — accessed via `Countly.sharedInstance().sessions`. */
export class SessionsApi {
  private readonly logger: Logger;
  private readonly module: ModuleSessions;

  constructor(logger: Logger, module: ModuleSessions) {
    this.logger = logger;
    this.module = module;
  }

  public async beginSession(): Promise<void> {
    this.logger.i('[Sessions] Calling beginSession');
    await this.module.beginSession();
  }

  public async updateSession(): Promise<void> {
    this.logger.i('[Sessions] Calling updateSession');
    await this.module.updateSession();
  }

  public async endSession(): Promise<void> {
    this.logger.i('[Sessions] Calling endSession');
    await this.module.endSession();
  }
}
