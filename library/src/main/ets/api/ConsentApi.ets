import { Logger } from '../internal/Logger';
import { ModuleConsent } from '../internal/modules/ModuleConsent';

/**
 * User-facing consent surface, accessed via `Countly.sharedInstance().consent`.
 *
 * The integrator-callable surface is intentionally narrow:
 *   - `giveConsentAll()` / `removeConsentAll()`, the only mutators. With
 *     unknown consent mode in particular these are the *resolution* signals
 *     that exit unknown mode; the instance keeps running on either path
 *     (give resumes the queue, remove ships a revocation snapshot and locks
 *     runtime consent, see ConsentConfig.enableUnknownConsentMode).
 *   - `checkAllConsent()`, read-only diagnostic.
 *
 * The per-feature mutators (`giveConsent`, `removeConsent`, `setConsent`,
 * `getConsent`) and the feature-group helpers (`createFeatureGroup`,
 * `setConsentFeatureGroup`) are deliberately NOT exposed. Module-level code
 * that needs them reads/writes via `instance.consentModule.*` (which is
 * `public readonly @internal` on `CountlyInstance`, same pattern as
 * `viewsModule` / `deviceIdModule`). Tests use the same path.
 */
export class ConsentApi {
  private readonly logger: Logger;
  private readonly module: ModuleConsent;

  constructor(logger: Logger, module: ModuleConsent) {
    this.logger = logger;
    this.module = module;
  }

  public giveConsentAll(): void {
    this.logger.i('[Consent] Calling giveConsentAll');
    this.module.giveConsentAll();
  }

  public removeConsentAll(): void {
    this.logger.i('[Consent] Calling removeConsentAll');
    this.module.removeConsentAll();
  }

  public checkAllConsent(): boolean {
    this.logger.i('[Consent] Calling checkAllConsent');
    return this.module.checkAllConsent();
  }
}
