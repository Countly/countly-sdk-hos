import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { DeviceInfo } from '../DeviceInfo';
import { Utils } from '../Utils';
import { ConsentChangeSource, CountlyFeature } from '../../types/Types';

export interface FirstViewFlagHost {
  reset(): void;
}

class NoopFirstViewFlagHost implements FirstViewFlagHost {
  reset(): void { /* no-op default */ }
}

class EndSessionOptions {
  emit: boolean;
  constructor(emit: boolean) {
    this.emit = emit;
  }
}

/**
 * Session tracking. Three modes:
 *   1. Fully automatic (default) — driven by foreground/background callbacks
 *      that the host app forwards via onEnterForeground/onEnterBackground.
 *      An internal counter handles "multiple UI components" so quick
 *      rotations don't fire multiple begin/end pairs.
 *   2. Manual — host calls beginSession/updateSession/endSession.
 *   3. Hybrid manual — host calls begin/end; updates are still automatic.
 */
export class ModuleSessions extends ModuleBase {
  private core: SdkCore;
  private sessionActive: boolean = false;
  private sessionStartMs: number = 0;
  private lastUpdateMs: number = 0;
  private updateTimer: number = 0;
  private lifecycleCounter: number = 0;
  private firstViewFlagHost: FirstViewFlagHost = new NoopFirstViewFlagHost();

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleSessions] Initialising');
    this.core = core;
  }

  public setFirstViewFlagHost(host: FirstViewFlagHost): void {
    this.firstViewFlagHost = host;
  }

  public override async onInit(): Promise<void> {
    // No-op: in auto mode, sessions start from onEnterForeground driven by the
    // host's lifecycle callback; in manual mode the host drives beginSession().
  }

  public override onEnterForeground(): void {
    if (this.config.manualSessionControl) return;
    this.lifecycleCounter++;
    if (this.lifecycleCounter === 1) {
      // Rejection log + sessionActive rollback so a begin_session enqueue
      // failure doesn't leave the module thinking a session is running (which
      // would cause subsequent update/end ticks to enqueue under a session the
      // server never saw).
      this.beginSessionInternal().catch((err: Object) => {
        this.sessionActive = false;
        this.config.logger.e(`[ModuleSessions] onEnterForeground, beginSessionInternal rejected: ${err}`);
      });
    }
  }

  public override onEnterBackground(): void {
    if (this.config.manualSessionControl) return;
    this.lifecycleCounter--;
    if (this.lifecycleCounter < 0) {
      this.config.logger.e('[ModuleSessions] onEnterBackground, unbalanced lifecycle (counter went negative) — clamping to 0');
      this.lifecycleCounter = 0;
      return;
    }
    if (this.lifecycleCounter === 0) {
      this.endSessionInternal().catch((err: Object) => {
        this.config.logger.e(`[ModuleSessions] onEnterBackground, endSessionInternal rejected: ${err}`);
      });
    }
  }

  public async beginSession(): Promise<void> {
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] beginSession, manual session control not enabled — ignored');
      return;
    }
    await this.beginSessionInternal();
  }

  public async updateSession(): Promise<void> {
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] updateSession, manual session control not enabled — ignored');
      return;
    }
    if (this.config.manualSessionHybridMode) {
      this.config.logger.d('[ModuleSessions] updateSession, hybrid mode handles updates automatically — ignored');
      return;
    }
    await this.sendUpdate();
  }

  public async endSession(): Promise<void> {
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] endSession, manual session control not enabled — ignored');
      return;
    }
    await this.endSessionInternal();
  }

  public isSessionActive(): boolean { return this.sessionActive; }

  private async beginSessionInternal(): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.SESSIONS)) {
      this.config.logger.v('[ModuleSessions] beginSessionInternal, no sessions consent');
      return;
    }
    // SDK Behavior Settings `st` flag — server-side killswitch for session
    // tracking. Independent of consent: an integrator-granted consent does
    // not override a server-side disable.
    if (!this.config.serverConfig.sessionTrackingEnabled) {
      this.config.logger.d('[ModuleSessions] beginSessionInternal, session tracking disabled by server config — ignored');
      return;
    }
    if (this.sessionActive) {
      this.config.logger.w('[ModuleSessions] beginSessionInternal, session already active — ignored');
      return;
    }
    this.sessionActive = true;
    this.sessionStartMs = Date.now();
    this.lastUpdateMs = this.sessionStartMs;
    this.firstViewFlagHost.reset();

    await this.core.saveUserProfileIfPending();

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['begin_session'] = '1';
    const metrics: Record<string, string> = DeviceInfo.collect(this.config.appVersion, this.config.metricOverride);
    params['metrics'] = JSON.stringify(metrics);

    // Location on begin_session: attach cached values unless disabled.
    this.attachLocation(params);

    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);

    this.config.logger.i('[ModuleSessions] beginSessionInternal, session started');
    this.scheduleUpdateTimer();
  }

  private async sendUpdate(): Promise<void> {
    if (!this.sessionActive) return;
    // Consent may have flipped between ticks — re-check here before hitting
    // the queue so revocation takes effect promptly.
    if (!this.core.consentModule.hasConsent(CountlyFeature.SESSIONS)) return;
    // SBS `st` may have flipped too — same pattern as consent.
    if (!this.config.serverConfig.sessionTrackingEnabled) return;
    const now: number = Date.now();
    const elapsed: number = Math.round((now - this.lastUpdateMs) / 1000);
    if (elapsed <= 0) return;

    await this.core.saveUserProfileIfPending();

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['session_duration'] = String(elapsed);
    const body: string = Utils.buildQueryString(params);
    // Only advance lastUpdateMs after the enqueue resolves, so an enqueue
    // failure doesn't skip the duration window for the next tick.
    await this.core.requestQueue.enqueue(body);
    this.lastUpdateMs = now;
    this.config.logger.d(`[ModuleSessions] sendUpdate, duration=${elapsed}s`);
  }

  private async endSessionInternal(options?: EndSessionOptions): Promise<void> {
    if (!this.sessionActive) return;
    if (this.updateTimer !== 0) {
      clearInterval(this.updateTimer);
      this.updateTimer = 0;
    }
    const now: number = Date.now();
    const elapsed: number = Math.round((now - this.lastUpdateMs) / 1000);
    this.sessionActive = false;
    this.firstViewFlagHost.reset();

    // When consent was just revoked, we still want to stop the timer and flip
    // sessionActive — but we MUST NOT enqueue an end_session request (that's
    // the whole point of consent revocation).
    if (options && !options.emit) return;

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['end_session'] = '1';
    if (elapsed > 0) params['session_duration'] = String(elapsed);
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
    this.config.logger.i(`[ModuleSessions] endSessionInternal, session ended (duration=${elapsed}s)`);
  }

  private scheduleUpdateTimer(): void {
    if (this.updateTimer !== 0) return;
    const intervalMs: number = this.config.sessionUpdateIntervalSec * 1000;
    this.updateTimer = setInterval(() => {
      if (this.config.manualSessionControl && !this.config.manualSessionHybridMode) return;
      this.sendUpdate().catch((err: Object) => {
        this.config.logger.e(`[ModuleSessions] updateTimer, sendUpdate rejected: ${err}`);
      });
    }, intervalMs) as number;
  }

  private attachLocation(params: Record<string, string>): void {
    const disabled: boolean = this.config.locationDisabled
      || !this.core.consentModule.hasConsent(CountlyFeature.LOCATION)
      || !this.config.serverConfig.locationTrackingEnabled;
    if (disabled) {
      params['location'] = '';
      return;
    }
    const country: string | null = this.config.initialLocationCountry;
    const city: string | null = this.config.initialLocationCity;
    const gps: string | null = this.config.initialLocationGps;
    const ip: string | null = this.config.initialLocationIp;
    if (country && country.length > 0) params['country_code'] = country;
    if (city && city.length > 0) params['city'] = city;
    if (gps && gps.length > 0) params['location'] = gps;
    if (ip && ip.length > 0) params['ip_address'] = ip;
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    // Android-parity: a device-id change without merge is a "user switch"
    // gesture. The old session belongs to the previous user — end it
    // silently (emit=false) so no end_session lands on the OLD id. The new
    // user's session only begins when the host re-fires onEnterForeground
    // (or explicitly calls beginSession in manual mode). Don't auto-restart
    // here, even when consent is still in effect — the host hasn't told us
    // the new user is in foreground.
    if (this.sessionActive) {
      await this.endSessionInternal(new EndSessionOptions(false));
    }
    this.lifecycleCounter = 0;
  }

  public override async onConsentChanged(_added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    // Sessions consent revoked mid-session → stop the timer and clear state,
    // but DO NOT emit a final end_session request. The whole point of
    // revocation is to stop sending session data.
    //
    // Skip the device-id-changed-notMerged source: that path runs the consent
    // reset upstream of the device-id fan-out, so this hook would land first
    // and end the session with emit=false BEFORE onDeviceIdChangedNotMerged
    // gets a chance to emit it. Defer to the device-id hook instead.
    if (source === ConsentChangeSource.DeviceIDChangedNotMerged) return;
    if (removed.indexOf(CountlyFeature.SESSIONS) !== -1 && this.sessionActive) {
      await this.endSessionInternal(new EndSessionOptions(false));
    }
  }

  public override async onHalt(): Promise<void> {
    if (this.updateTimer !== 0) {
      clearInterval(this.updateTimer);
      this.updateTimer = 0;
    }
    if (this.sessionActive) await this.endSessionInternal();
  }
}
