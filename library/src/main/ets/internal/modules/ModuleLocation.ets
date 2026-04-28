import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { ConsentChangeSource, CountlyFeature } from '../../types/Types';

/**
 * Location is memory-only (per dev guide). Auto begin_session reads from the
 * config directly, so this module only drives the *post-init* setLocation /
 * disableLocation flows, which send a location request immediately when a
 * session is already running or auto-sessions are off.
 */
export class ModuleLocation extends ModuleBase {
  private core: SdkCore;
  private sessionStartedProvider: () => boolean = () => false;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleLocation] Initialising');
    this.core = core;
  }

  public setSessionStartedProvider(cb: () => boolean): void {
    this.sessionStartedProvider = cb;
  }

  public async setLocation(country: string | null, city: string | null, gps: string | null, ip: string | null): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.LOCATION)) {
      this.config.logger.v('[ModuleLocation] setLocation, no location consent — ignored');
      return;
    }
    // SDK Behavior Settings `lt` killswitch — server-side disable.
    if (!this.config.serverConfig.locationTrackingEnabled) {
      this.config.logger.d('[ModuleLocation] setLocation, location tracking disabled by server config — ignored');
      return;
    }
    const anyNonNull: boolean = !!(country || city || gps || ip);
    if (anyNonNull) {
      this.config.locationDisabled = false;
    }
    if ((country && !city) || (!country && city)) {
      this.config.logger.w('[ModuleLocation] setLocation, country and city must be set together — the unpaired value will still be sent but may be ignored server-side');
    }
    this.config.initialLocationCountry = country;
    this.config.initialLocationCity = city;
    this.config.initialLocationGps = gps;
    this.config.initialLocationIp = ip;

    if (this.sessionStartedProvider()) {
      // Send immediately (without IP — IP only geolocates with begin_session).
      const params: Record<string, string> = this.core.requestBuilder.baseParams();
      if (country) params['country_code'] = country;
      if (city) params['city'] = city;
      if (gps) params['location'] = gps;
      const body: string = Utils.buildQueryString(params);
      await this.core.requestQueue.enqueue(body);
    }
  }

  public async disableLocation(): Promise<void> {
    this.config.locationDisabled = true;
    this.config.initialLocationCountry = null;
    this.config.initialLocationCity = null;
    this.config.initialLocationGps = null;
    this.config.initialLocationIp = null;

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['location'] = '';
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
  }

  public override async onConsentChanged(added: string[], removed: string[], _source: ConsentChangeSource): Promise<void> {
    if (removed.indexOf(CountlyFeature.LOCATION) !== -1) {
      // Erasure request per dev guide.
      const params: Record<string, string> = this.core.requestBuilder.baseParams();
      params['location'] = '';
      const body: string = Utils.buildQueryString(params);
      await this.core.requestQueue.enqueue(body);
    }
  }
}
