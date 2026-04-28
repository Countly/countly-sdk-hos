import { Logger } from '../internal/Logger';
import { ModuleConsent } from '../internal/modules/ModuleConsent';

/** User-facing consent surface — accessed via `Countly.sharedInstance().consent`. */
export class ConsentApi {
  private readonly logger: Logger;
  private readonly module: ModuleConsent;

  constructor(logger: Logger, module: ModuleConsent) {
    this.logger = logger;
    this.module = module;
  }

  public giveConsent(featureNames: string[]): void {
    this.logger.i(`[Consent] Calling giveConsent, features=[${featureNames ? featureNames.join(',') : ''}]`);
    this.module.giveConsent(featureNames);
  }

  public removeConsent(featureNames: string[]): void {
    this.logger.i(`[Consent] Calling removeConsent, features=[${featureNames ? featureNames.join(',') : ''}]`);
    this.module.removeConsent(featureNames);
  }

  public giveConsentAll(): void {
    this.logger.i('[Consent] Calling giveConsentAll');
    this.module.giveConsentAll();
  }

  public removeConsentAll(): void {
    this.logger.i('[Consent] Calling removeConsentAll');
    this.module.removeConsentAll();
  }

  public getConsent(featureName: string): boolean {
    this.logger.i(`[Consent] Calling getConsent, feature=[${featureName}]`);
    return this.module.hasConsent(featureName);
  }

  public setConsent(featureNames: string[], given: boolean): void {
    this.logger.i(`[Consent] Calling setConsent, given=[${given}] features=[${featureNames ? featureNames.join(',') : ''}]`);
    this.module.setConsent(featureNames, given);
  }

  public createFeatureGroup(groupName: string, features: string[]): void {
    this.logger.i(`[Consent] Calling createFeatureGroup, group=[${groupName}]`);
    this.module.createFeatureGroup(groupName, features);
  }

  public setConsentFeatureGroup(groupName: string, given: boolean): void {
    this.logger.i(`[Consent] Calling setConsentFeatureGroup, group=[${groupName}] given=[${given}]`);
    this.module.setConsentFeatureGroup(groupName, given);
  }

  public checkAllConsent(): boolean {
    this.logger.i('[Consent] Calling checkAllConsent');
    return this.module.checkAllConsent();
  }
}
