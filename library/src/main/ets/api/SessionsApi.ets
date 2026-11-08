import { Logger } from '../internal/Logger';
import { ModuleSessions } from '../internal/modules/ModuleSessions';

/** User-facing sessions surface, accessed via `Countly.sharedInstance().sessions`. */
export class SessionsApi {
  private readonly logger: Logger;
  private readonly module: ModuleSessions;

  constructor(logger: Logger, module: ModuleSessions) {
    this.logger = logger;
    this.module = module;
  }

  public async beginSession(): Promise<void> {
    this.logger.i('[Sessions] Calling beginSession');
    this.logger.healthUsage('sessions', 'begin');
    await this.module.beginSession();
  }

  public async updateSession(): Promise<void> {
    this.logger.i('[Sessions] Calling updateSession');
    this.logger.healthUsage('sessions', 'update');
    await this.module.updateSession();
  }

  public async endSession(): Promise<void> {
    this.logger.i('[Sessions] Calling endSession');
    this.logger.healthUsage('sessions', 'end');
    await this.module.endSession();
  }
}
