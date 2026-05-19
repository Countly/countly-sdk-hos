import ApplicationStateChangeCallback from '@ohos.app.ability.ApplicationStateChangeCallback';
import AbilityLifecycleCallback from '@ohos.app.ability.AbilityLifecycleCallback';
import EnvironmentCallback from '@ohos.app.ability.EnvironmentCallback';
import UIAbility from '@ohos.app.ability.UIAbility';
import { Configuration as SystemConfig } from '@ohos.app.ability.Configuration';
import window from '@ohos.window';
import { Logger } from './Logger';
import { common } from '@kit.AbilityKit';

/**
 * `ApplicationStateChangeCallback` is exported as a *class* (not an interface)
 * with un-implemented method declarations. ArkTS strict mode bans structural
 * typing for classes, so we can't pass an object literal, we must extend the
 * class. Subclassing here keeps the body tightly scoped: the constructor takes
 * the two HarmonyOS lifecycle hooks and forwards them, swallowing any throws so
 * the platform never sees an SDK-side error from inside the callback.
 */
class CountlyAppStateObserver extends ApplicationStateChangeCallback {
  private readonly fg: () => void;
  private readonly bg: () => void;
  private readonly logger: Logger;

  constructor(logger: Logger, fg: () => void, bg: () => void) {
    super();
    this.logger = logger;
    this.fg = fg;
    this.bg = bg;
  }

  onApplicationForeground(): void {
    try { this.fg(); }
    catch (err) { this.logger.e(`[LifecycleObserver] onForeground threw: ${err}`); }
  }

  onApplicationBackground(): void {
    try { this.bg(); }
    catch (err) { this.logger.e(`[LifecycleObserver] onBackground threw: ${err}`); }
  }
}

/**
 * Subclass for the abilityLifecycle subscription. We only act on
 * `onAbilityForeground`, the moment a UIAbility becomes the user's focused
 * screen, and forward its short + long name to the callback. The other
 * eight hooks are stubbed because `AbilityLifecycleCallback` is an
 * abstract-ish class: ArkTS requires every method body even when empty.
 *
 * Long name is synthesised as `${bundleName}.${name}` so integrators get
 * a fully-qualified ability name (HMOS `abilityInfo.name` is just the
 * simple class name). Without the synthesis, short and long modes would
 * be identical strings.
 */
class CountlyAbilityLifecycleObserver extends AbilityLifecycleCallback {
  private readonly logger: Logger;
  private readonly onAbilityForegroundCallback: (shortName: string, fullName: string) => void;

  constructor(logger: Logger, onAbilityForegroundCallback: (shortName: string, fullName: string) => void) {
    super();
    this.logger = logger;
    this.onAbilityForegroundCallback = onAbilityForegroundCallback;
  }

  onAbilityCreate(_ability: UIAbility): void { /* not tracked */ }
  onAbilityDestroy(_ability: UIAbility): void { /* not tracked */ }
  onAbilityBackground(_ability: UIAbility): void { /* not tracked, backgrounding is handled by lifecycleBackground */ }
  onAbilityContinue(_ability: UIAbility): void { /* not tracked */ }
  onWindowStageCreate(_ability: UIAbility, _windowStage: window.WindowStage): void { /* not tracked */ }
  onWindowStageDestroy(_ability: UIAbility, _windowStage: window.WindowStage): void { /* not tracked */ }
  onWindowStageActive(_ability: UIAbility, _windowStage: window.WindowStage): void { /* not tracked */ }
  onWindowStageInactive(_ability: UIAbility, _windowStage: window.WindowStage): void { /* not tracked */ }

  onAbilityForeground(ability: UIAbility): void {
    try {
      const info = ability.context.abilityInfo;
      const shortName: string = info.name;
      const bundleName: string = info.bundleName;
      const fullName: string = bundleName.length > 0 && shortName.length > 0
        ? `${bundleName}.${shortName}`
        : shortName;
      this.onAbilityForegroundCallback(shortName, fullName);
    } catch (err) {
      this.logger.w(`[LifecycleObserver] onAbilityForeground name extraction failed: ${err}`);
    }
  }
}

/**
 * Subclass for the environment subscription. We act on
 * `onConfigurationUpdated`, fires when the system configuration changes
 * (orientation flip, locale change, theme switch). The callback receives
 * the updated Configuration object so the caller can inspect specific
 * fields. `onMemoryLevel` is implemented as a no-op stub for now; future
 * work could wire it to drop in-memory caches under pressure.
 */
class CountlyEnvironmentObserver extends EnvironmentCallback {
  private readonly logger: Logger;
  private readonly onConfigUpdatedCallback: (config: SystemConfig) => void;

  constructor(logger: Logger, onConfigUpdatedCallback: (config: SystemConfig) => void) {
    super();
    this.logger = logger;
    this.onConfigUpdatedCallback = onConfigUpdatedCallback;
  }

  onConfigurationUpdated(config: SystemConfig): void {
    try { this.onConfigUpdatedCallback(config); }
    catch (err) { this.logger.e(`[LifecycleObserver] onConfigurationUpdated threw: ${err}`); }
  }

  onMemoryLevel(_level: number): void { /* not tracked, see class doc for future use */ }
}

/**
 * Buffer for an ability foreground event captured before `markReady()`.
 * ArkTS strict mode bans typed object literals, so a named class is the
 * idiomatic shape for this small pair.
 */
class PendingAutoView {
  shortName: string;
  fullName: string;
  constructor(shortName: string, fullName: string) {
    this.shortName = shortName;
    this.fullName = fullName;
  }
}

/**
 * Per-instance HarmonyOS lifecycle subscription manager.
 *
 * Each `CountlyInstance` owns its own observer, registers on init, and
 * deregisters on halt. Multi-instance setups end up with one observer per
 * instance, the platform allows this, each fires independently, and each
 * routes to its own instance's `lifecycleForeground` / `lifecycleBackground`
 * (and, when configured, automatic view tracking).
 *
 * Three subscription types:
 *
 * 1. `applicationStateChange`, always registered. Drives session fg/bg.
 *
 * 2. `abilityLifecycle`, registered only when an `onAbilityForeground`
 *    callback is supplied (i.e. when `enableAutomaticViewTracking()` is
 *    set). Powers ability-level auto-view tracking. The callback receives
 *    both the short name and the synthesised long name; the caller (in
 *    `CountlyInstance`) picks based on `automaticViewShortNames`.
 *
 * 3. `environment`, registered only when an `onConfigurationUpdated`
 *    callback is supplied (i.e. when `trackOrientationChanges` is set,
 *    the default). Drives `[CLY]_orientation` event emission on rotate.
 *    `onMemoryLevel` is wired through but currently no-op'd; future work.
 *
 * Why instance-scoped: each instance owns its full lifecycle including
 * subscription cleanup. A `haltOne` would otherwise have to coordinate
 * with a shared observer to know whether to deregister, instance-scoped,
 * the rule is trivial: halt → deregister.
 *
 * Resilience: registration failures (no context, ApplicationContext API
 * unavailable, observer rejected) downgrade to debug logs and the
 * remaining subscription paths still try independently. The instance
 * still works, integrators can drive lifecycle manually via
 * `Countly.lifecycleForegroundAll` / `lifecycleBackgroundAll`.
 *
 * --- Future extension points (NOT wired today) ---
 *
 * `EnvironmentCallback.onMemoryLevel` is wired through but no-op'd. A
 * future extension would route memory-pressure events to modules that
 * maintain caches (request queue, event aggregator) so they can drop
 * non-critical state under pressure.
 *
 * Locale change tracking via `onConfigurationUpdated` is not currently
 * forwarded, only orientation. Adding it would require ModuleViews /
 * ModuleEvents to expose a locale-changed hook that re-derives the `la`
 * request param.
 */
export class LifecycleObserver {
  // applicationStateChange uses an observer-object handle, not a numeric id.
  // We track the observer reference so deregister() can pass the same
  // instance back to off(). abilityLifecycle and environment use the
  // numeric-id form, so the callback id alone is enough, no need to retain
  // the observer reference once registration succeeds.
  private appStateObserver: CountlyAppStateObserver | null = null;
  private abilityCallbackId: number = -1;
  private envCallbackId: number = -1;
  private appContext: common.ApplicationContext | null = null;
  private readonly logger: Logger;
  private readonly onForeground: () => void;
  private readonly onBackground: () => void;
  private readonly onAbilityForeground: ((shortName: string, fullName: string) => void) | null;
  private readonly onConfigurationUpdated: ((config: SystemConfig) => void) | null;

  // "Ready" gate. `register()` runs synchronously at the TOP of init(), well
  // before storage / device-id / module inits resolve, so the platform's
  // first foreground transition is never lost to a cold-boot race. But we
  // can't immediately dispatch into modules whose async init is still in
  // flight (request queue not loaded, device id unresolved, server config
  // not applied), so any platform event that arrives before `markReady()` is
  // buffered here and replayed once init has finished. We don't synthesise
  // anything, only platform-confirmed events ever fire downstream.
  private ready: boolean = false;
  private pendingFg: boolean = false;
  private pendingAutoView: PendingAutoView | null = null;

  constructor(
    logger: Logger,
    onForeground: () => void,
    onBackground: () => void,
    onAbilityForeground: ((shortName: string, fullName: string) => void) | null,
    onConfigurationUpdated: ((config: SystemConfig) => void) | null
  ) {
    this.logger = logger;
    this.onForeground = onForeground;
    this.onBackground = onBackground;
    this.onAbilityForeground = onAbilityForeground;
    this.onConfigurationUpdated = onConfigurationUpdated;
  }

  /**
   * Internal foreground dispatch. Buffered until `markReady()` so a platform
   * fg transition that fires while init's async pipeline is still running
   * doesn't reach modules whose state isn't loaded yet. Once ready, future
   * fg events dispatch immediately.
   */
  private dispatchFg(): void {
    if (!this.ready) {
      this.pendingFg = true;
      return;
    }
    this.onForeground();
  }

  /**
   * Internal background dispatch. A bg arriving while not-ready cancels any
   * pending fg AND any pending auto-view (the same way an actual bg + return
   * cycle would have): we never replay an out-of-date fg/auto-view after the
   * app has already moved on.
   */
  private dispatchBg(): void {
    if (!this.ready) {
      this.pendingFg = false;
      this.pendingAutoView = null;
      return;
    }
    this.onBackground();
  }

  /**
   * Internal auto-view dispatch. Same buffering as fg/bg, the most recent
   * pending ability wins, since `startAutoStoppedView` would auto-stop any
   * earlier one anyway.
   */
  private dispatchAutoView(shortName: string, fullName: string): void {
    const cb: ((shortName: string, fullName: string) => void) | null = this.onAbilityForeground;
    if (cb === null) return;
    if (!this.ready) {
      this.pendingAutoView = new PendingAutoView(shortName, fullName);
      return;
    }
    cb(shortName, fullName);
  }

  /**
   * Called by `CountlyInstance.init()` once every async init step has
   * completed. Flushes any platform events received during init in the order
   * they would have happened, fg before any auto-view that may have been
   * captured. Idempotent: subsequent calls flip nothing.
   */
  public markReady(): void {
    if (this.ready) return;
    this.ready = true;
    if (this.pendingFg) {
      this.pendingFg = false;
      this.onForeground();
    }
    if (this.pendingAutoView !== null) {
      const cb: ((shortName: string, fullName: string) => void) | null = this.onAbilityForeground;
      const pending: PendingAutoView = this.pendingAutoView;
      this.pendingAutoView = null;
      if (cb !== null) cb(pending.shortName, pending.fullName);
    }
  }

  /**
   * Subscribe. Idempotent, calling twice is a no-op so re-init paths
   * don't double-subscribe.
   *
   * Note: HMOS lifecycle events (`applicationStateChange`,
   * `abilityLifecycle`, `environment`) fire on transitions only and never
   * replay the current state. If `register()` is called after the platform
   * has already fired the cold-boot foreground transition, that transition
   * is lost, the recommended init point is `AbilityStage.onCreate`, which
   * runs before any UIAbility, so registration is always in place ahead
   * of every transition.
   */
  public register(ctx: common.Context | null): void {
    if (this.appStateObserver !== null) return;
    if (ctx === null) {
      this.logger.d('[LifecycleObserver] no context, auto-lifecycle disabled, integrator must drive lifecycleForegroundAll/Background manually');
      return;
    }
    let appCtx: common.ApplicationContext;
    try {
      appCtx = ctx.getApplicationContext();
    } catch (err) {
      // Debug, not warn: the test harness uses a bare `{}` context and
      // production hosts that lack ApplicationContext (rare, e.g. service
      // extension contexts) shouldn't show up in HealthCheck error counts.
      this.logger.d(`[LifecycleObserver] getApplicationContext unavailable, auto-lifecycle disabled: ${err}`);
      return;
    }
    if (appCtx === undefined || appCtx === null) {
      this.logger.d('[LifecycleObserver] applicationContext null, auto-lifecycle disabled');
      return;
    }
    this.appContext = appCtx;

    // applicationStateChange, always. Route through dispatchFg/dispatchBg
    // so events received before `markReady()` are buffered safely.
    try {
      const observer: CountlyAppStateObserver = new CountlyAppStateObserver(
        this.logger,
        (): void => this.dispatchFg(),
        (): void => this.dispatchBg()
      );
      appCtx.on('applicationStateChange', observer);
      this.appStateObserver = observer;
      this.logger.d('[LifecycleObserver] applicationStateChange registered');
    } catch (err) {
      this.logger.w(`[LifecycleObserver] applicationStateChange.on failed: ${err}`);
    }

    // abilityLifecycle, only if a callback was supplied at construction.
    // Independently logged so registration failures of one don't poison
    // the other. Routed through dispatchAutoView for the same buffering.
    if (this.onAbilityForeground !== null) {
      try {
        const observer: CountlyAbilityLifecycleObserver = new CountlyAbilityLifecycleObserver(
          this.logger,
          (s: string, f: string): void => this.dispatchAutoView(s, f)
        );
        this.abilityCallbackId = appCtx.on('abilityLifecycle', observer);
        this.logger.d(`[LifecycleObserver] abilityLifecycle registered, id=${this.abilityCallbackId}`);
      } catch (err) {
        this.logger.w(`[LifecycleObserver] abilityLifecycle.on failed, auto-view tracking disabled: ${err}`);
      }
    }

    // environment, only if an onConfigurationUpdated callback was supplied
    // (i.e. trackOrientationChanges is on).
    const envCb: ((config: SystemConfig) => void) | null = this.onConfigurationUpdated;
    if (envCb !== null) {
      try {
        const observer: CountlyEnvironmentObserver = new CountlyEnvironmentObserver(this.logger, envCb);
        this.envCallbackId = appCtx.on('environment', observer);
        this.logger.d(`[LifecycleObserver] environment registered, id=${this.envCallbackId}`);
      } catch (err) {
        this.logger.w(`[LifecycleObserver] environment.on failed, orientation auto-tracking disabled: ${err}`);
      }
    }
  }

  /**
   * Unsubscribe everything. Safe to call multiple times, no-op after the
   * first successful deregister of each subscription.
   */
  public deregister(): void {
    if (this.appContext === null) return;
    if (this.appStateObserver !== null) {
      try { this.appContext.off('applicationStateChange', this.appStateObserver); }
      catch (err) { this.logger.w(`[LifecycleObserver] deregister applicationStateChange failed: ${err}`); }
      this.appStateObserver = null;
    }
    if (this.abilityCallbackId !== -1) {
      try { this.appContext.off('abilityLifecycle', this.abilityCallbackId); }
      catch (err) { this.logger.w(`[LifecycleObserver] deregister abilityLifecycle failed: ${err}`); }
      this.abilityCallbackId = -1;
    }
    if (this.envCallbackId !== -1) {
      try { this.appContext.off('environment', this.envCallbackId); }
      catch (err) { this.logger.w(`[LifecycleObserver] deregister environment failed: ${err}`); }
      this.envCallbackId = -1;
    }
    this.appContext = null;
    // Reset the ready-gate state so a subsequent re-init via initShared/
    // createInstance (e.g. tests doing haltAll → initShared again) starts
    // clean, without this a fresh instance would see ready=true from the
    // halted predecessor and skip its own buffering window.
    this.ready = false;
    this.pendingFg = false;
    this.pendingAutoView = null;
  }

  /** Test/diagnostic helper. */
  public isRegistered(): boolean {
    return this.appStateObserver !== null;
  }
}
