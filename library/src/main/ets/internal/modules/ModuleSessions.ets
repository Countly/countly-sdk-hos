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

/**
 * Session tracking. Three modes:
 *   1. Fully automatic (default), driven by foreground/background callbacks
 *      that the host app forwards via onEnterForeground/onEnterBackground.
 *      An internal counter handles "multiple UI components" so quick
 *      rotations don't fire multiple begin/end pairs.
 *   2. Manual, host calls beginSession/updateSession/endSession.
 *   3. Hybrid manual, host calls begin/end; updates are still automatic.
 */
export class ModuleSessions extends ModuleBase {
  private core: SdkCore;
  private sessionActive: boolean = false;
  private sessionStartMs: number = 0;
  private lastUpdateMs: number = 0;
  // null = no timer scheduled (see ModuleConsent.pendingCoalesceTimer for the
  // sentinel-collision rationale: HMOS's setInterval may legitimately return 0).
  private updateTimer: number | null = null;
  private lifecycleCounter: number = 0;
  private firstViewFlagHost: FirstViewFlagHost = new NoopFirstViewFlagHost();
  // Hook called immediately after begin_session is enqueued so the host
  // (CountlyInstance) can emit a forced orientation baseline. Default
  // no-op so the module remains usable in tests that don't wire the emitter.
  private orientationBaselineEmitter: () => void = (): void => { /* no-op default */ };

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleSessions] Initialising');
    this.core = core;
  }

  public setFirstViewFlagHost(host: FirstViewFlagHost): void {
    this.firstViewFlagHost = host;
  }

  /**
   * Wire the post-begin_session orientation baseline emitter. Called once
   * by `CountlyInstance` during construction. Implementations should
   * read the platform display, gate on `trackOrientationChanges` +
   * registration state, and call `viewsModule.updateOrientation(mode, true)`
   *, the `true` bypasses the dedupe so every begin_session gets a fresh
   * baseline event.
   */
  public setOrientationBaselineEmitter(emitter: () => void): void {
    this.orientationBaselineEmitter = emitter;
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
      // WARNING level, not ERROR: this is a defensive guard for
      // integrators who manually fan out `lifecycleBackgroundAll()`
      // (e.g. demo apps with explicit fg/bg buttons). The SDK clamps
      // and continues; nothing is actually broken.
      this.config.logger.w('[ModuleSessions] onEnterBackground, unbalanced lifecycle (counter went negative), clamping to 0');
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
    if (this.rejectIfHalted('ModuleSessions', 'beginSession')) return;
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] beginSession, manual session control not enabled, ignored');
      return;
    }
    await this.beginSessionInternal();
  }

  public async updateSession(): Promise<void> {
    if (this.rejectIfHalted('ModuleSessions', 'updateSession')) return;
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] updateSession, manual session control not enabled, ignored');
      return;
    }
    if (this.config.manualSessionHybridMode) {
      this.config.logger.d('[ModuleSessions] updateSession, hybrid mode handles updates automatically, ignored');
      return;
    }
    await this.sendUpdate();
  }

  public async endSession(): Promise<void> {
    if (this.rejectIfHalted('ModuleSessions', 'endSession')) return;
    if (!this.config.manualSessionControl) {
      this.config.logger.w('[ModuleSessions] endSession, manual session control not enabled, ignored');
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
    // SDK Behavior Settings `st` flag, server-side killswitch for session
    // tracking. Independent of consent: an integrator-granted consent does
    // not override a server-side disable.
    if (!this.config.serverConfig.sessionTrackingEnabled) {
      this.config.logger.d('[ModuleSessions] beginSessionInternal, session tracking disabled by server config, ignored');
      return;
    }
    if (this.sessionActive) {
      this.config.logger.w('[ModuleSessions] beginSessionInternal, session already active, ignored');
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

    // Orientation baseline, fires AFTER begin_session is in the request
    // queue so the events batch that carries the orientation event is
    // ordered after the begin_session URL request on the wire. Forced
    // (dedupe bypassed) so every begin_session gets a fresh orientation
    // event even when the orientation hasn't changed since the previous session.
    this.orientationBaselineEmitter();

    this.config.logger.i('[ModuleSessions] beginSessionInternal, session started');
    this.scheduleUpdateTimer();
  }

  private async sendUpdate(): Promise<void> {
    if (!this.sessionActive) return;
    // Consent may have flipped between ticks, re-check here before hitting
    // the queue so revocation takes effect promptly.
    if (!this.core.consentModule.hasConsent(CountlyFeature.SESSIONS)) return;
    // SBS `st` may have flipped too, same pattern as consent.
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

  private async endSessionInternal(emit: boolean = true): Promise<void> {
    if (!this.sessionActive) return;
    if (this.updateTimer !== null) {
      clearInterval(this.updateTimer);
      this.updateTimer = null;
    }
    const now: number = Date.now();
    const elapsed: number = Math.round((now - this.lastUpdateMs) / 1000);
    this.sessionActive = false;
    this.firstViewFlagHost.reset();

    // When consent was just revoked, we still want to stop the timer and flip
    // sessionActive, but we MUST NOT enqueue an end_session request (that's
    // the whole point of consent revocation).
    if (!emit) return;

    // Flush any buffered events BEFORE enqueueing end_session so the events
    // request lands inside the session window (begin..end) on the server.
    // Without this flush, pending events would have to wait for the
    // eventsModule.onEnterBackground pass that follows in `lifecycleBackground`,
    // which lands them AFTER end_session in the queue (wrong order, orphans
    // events server-side).
    await this.core.flushEvents();
    // Then ship pending user-profile changes so user_details lands between
    // events and end_session, mid-session UP mutations must fall inside
    // the session window on the server.
    await this.core.saveUserProfileIfPending();

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['end_session'] = '1';
    if (elapsed > 0) params['session_duration'] = String(elapsed);
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
    this.config.logger.i(`[ModuleSessions] endSessionInternal, session ended (duration=${elapsed}s)`);
  }

  private scheduleUpdateTimer(): void {
    if (this.updateTimer !== null) return;
    const intervalMs: number = this.config.sessionUpdateIntervalSec * 1000;
    this.updateTimer = setInterval(() => {
      if (this.config.manualSessionControl && !this.config.manualSessionHybridMode) return;
      this.heartbeatTick().catch((err: Object) => {
        this.config.logger.e(`[ModuleSessions] updateTimer, heartbeatTick rejected: ${err}`);
      });
    }, intervalMs) as number;
  }

  /**
   * Heartbeat cascade: after the session-duration enqueue, force-flush
   * events and run a second user-profile save. Without these, events
   * buffered mid-session sit until the size threshold or background, and
   * UP changes wait for the next mutation auto-trigger. Manual
   * `updateSession()` keeps the lighter contract (just saveUP →
   * update_session); only the timer tick reaches this fuller cascade.
   */
  private async heartbeatTick(): Promise<void> {
    await this.sendUpdate();
    await this.core.flushEvents();
    await this.core.saveUserProfileIfPending();
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

  /**
   * Pre-swap closer for the changeWithoutMerge path. CountlyInstance's
   * pre-swap hook calls this UNDER THE OLD ID, before commit, so the wire
   * `end_session=1` carries the previous user's device_id. Emit only in
   * non-manual mode, the caller is responsible for checking
   * `manualSessionControl`.
   */
  public async endSessionForDeviceIdChange(): Promise<void> {
    if (!this.sessionActive) return;
    await this.endSessionInternal(true);
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    // The session-end emission already happened pre-swap (see
    // CountlyInstance's `setBeforeNonMergedSwapHook`). All that's left here
    // is resetting the lifecycle counter so a subsequent foreground replays
    // a clean begin_session under the new id.
    this.lifecycleCounter = 0;
  }

  public override async onConsentChanged(_added: string[], removed: string[], source: ConsentChangeSource): Promise<void> {
    // Sessions consent revoked mid-session → emit a final end_session so the
    // server closes the session window. `endSessionInternal` has no internal
    // consent gate, so passing emit=true ships the request even though the
    // consent map already reflects the revocation.
    //
    // Skip the device-id-changed-notMerged source: that path runs the consent
    // reset from CountlyInstance's pre-swap hook, AFTER the hook has already
    // emitted end_session under the OLD id (when applicable). Letting this
    // hook fire too would either double-emit (non-manual mode) or wrongly
    // emit under the new id (manual mode, where end_session is skipped).
    if (source === ConsentChangeSource.DeviceIDChangedNotMerged) return;
    if (removed.indexOf(CountlyFeature.SESSIONS) !== -1 && this.sessionActive) {
      await this.endSessionInternal(true);
    }
  }

  public override async onHalt(): Promise<void> {
    if (this.updateTimer !== null) {
      clearInterval(this.updateTimer);
      this.updateTimer = null;
    }
    if (this.sessionActive) await this.endSessionInternal();
  }
}
