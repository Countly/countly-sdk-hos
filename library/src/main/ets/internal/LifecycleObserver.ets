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
 * typing for classes, so we can't pass an object literal — we must extend the
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
 * `onAbilityForeground` — the moment a UIAbility becomes the user's focused
 * screen — and forward its short + long name to the callback. The other
 * eight hooks are stubbed because `AbilityLifecycleCallback` is an
 * abstract-ish class: ArkTS requires every method body even when empty.
 *
 * Long name is synthesised as `${bundleName}.${name}` to give integrators
 * Android-like parity (Android `Activity.getName()` returns the
 * package-qualified name, but HMOS `abilityInfo.name` is just the simple
 * class name). Without the synthesis, short and long modes would be
 * identical strings on HOS.
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
  onAbilityBackground(_ability: UIAbility): void { /* not tracked — backgrounding is handled by lifecycleBackground */ }
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
 * `onConfigurationUpdated` — fires when the system configuration changes
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

  onMemoryLevel(_level: number): void { /* not tracked — see class doc for future use */ }
}

/**
 * Per-instance HarmonyOS lifecycle subscription manager.
 *
 * Each `CountlyInstance` owns its own observer, registers on init, and
 * deregisters on halt. Multi-instance setups end up with one observer per
 * instance — the platform allows this, each fires independently, and each
 * routes to its own instance's `lifecycleForeground` / `lifecycleBackground`
 * (and, when configured, automatic view tracking).
 *
 * Three subscription types:
 *
 * 1. `applicationStateChange` — always registered. Drives session fg/bg.
 *
 * 2. `abilityLifecycle` — registered only when an `onAbilityForeground`
 *    callback is supplied (i.e. when `enableAutomaticViewTracking()` is
 *    set). Powers ability-level auto-view tracking. The callback receives
 *    both the short name and the synthesised long name; the caller (in
 *    `CountlyInstance`) picks based on `automaticViewShortNames`.
 *
 * 3. `environment` — registered only when an `onConfigurationUpdated`
 *    callback is supplied (i.e. when `trackOrientationChanges` is set,
 *    the default). Drives `[CLY]_orientation` event emission on rotate.
 *    `onMemoryLevel` is wired through but currently no-op'd; future work.
 *
 * Why instance-scoped: each instance owns its full lifecycle including
 * subscription cleanup. A `haltOne` would otherwise have to coordinate
 * with a shared observer to know whether to deregister — instance-scoped,
 * the rule is trivial: halt → deregister.
 *
 * Resilience: registration failures (no context, ApplicationContext API
 * unavailable, observer rejected) downgrade to debug logs and the
 * remaining subscription paths still try independently. The instance
 * still works — integrators can drive lifecycle manually via
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
 * forwarded — only orientation. Adding it would require ModuleViews /
 * ModuleEvents to expose a locale-changed hook that re-derives the `la`
 * request param.
 */
export class LifecycleObserver {
  // applicationStateChange uses an observer-object handle, not a numeric id.
  // We track the observer reference so deregister() can pass the same
  // instance back to off(). abilityLifecycle and environment use the
  // numeric-id form.
  private appStateObserver: CountlyAppStateObserver | null = null;
  private abilityObserver: CountlyAbilityLifecycleObserver | null = null;
  private abilityCallbackId: number = -1;
  private envObserver: CountlyEnvironmentObserver | null = null;
  private envCallbackId: number = -1;
  private appContext: common.ApplicationContext | null = null;
  private readonly logger: Logger;
  private readonly onForeground: () => void;
  private readonly onBackground: () => void;
  private readonly onAbilityForeground: ((shortName: string, fullName: string) => void) | null;
  private readonly onConfigurationUpdated: ((config: SystemConfig) => void) | null;

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
   * Subscribe. Idempotent — calling twice is a no-op so re-init paths
   * don't double-subscribe.
   */
  public register(ctx: common.Context | null): void {
    if (this.appStateObserver !== null) return;
    if (ctx === null) {
      this.logger.d('[LifecycleObserver] no context — auto-lifecycle disabled, integrator must drive lifecycleForegroundAll/Background manually');
      return;
    }
    let appCtx: common.ApplicationContext;
    try {
      appCtx = ctx.getApplicationContext();
    } catch (err) {
      // Debug, not warn: the test harness uses a bare `{}` context and
      // production hosts that lack ApplicationContext (rare, e.g. service
      // extension contexts) shouldn't show up in HealthCheck error counts.
      this.logger.d(`[LifecycleObserver] getApplicationContext unavailable — auto-lifecycle disabled: ${err}`);
      return;
    }
    if (appCtx === undefined || appCtx === null) {
      this.logger.d('[LifecycleObserver] applicationContext null — auto-lifecycle disabled');
      return;
    }
    this.appContext = appCtx;

    // applicationStateChange — always
    try {
      const observer: CountlyAppStateObserver = new CountlyAppStateObserver(this.logger, this.onForeground, this.onBackground);
      appCtx.on('applicationStateChange', observer);
      this.appStateObserver = observer;
      this.logger.d('[LifecycleObserver] applicationStateChange registered');
    } catch (err) {
      this.logger.w(`[LifecycleObserver] applicationStateChange.on failed: ${err}`);
    }

    // abilityLifecycle — only if a callback was supplied at construction.
    // Independently logged so registration failures of one don't poison
    // the other.
    const abilityCb: ((shortName: string, fullName: string) => void) | null = this.onAbilityForeground;
    if (abilityCb !== null) {
      try {
        const observer: CountlyAbilityLifecycleObserver = new CountlyAbilityLifecycleObserver(this.logger, abilityCb);
        const id: number = appCtx.on('abilityLifecycle', observer);
        this.abilityObserver = observer;
        this.abilityCallbackId = id;
        this.logger.d(`[LifecycleObserver] abilityLifecycle registered, id=${id}`);
      } catch (err) {
        this.logger.w(`[LifecycleObserver] abilityLifecycle.on failed — auto-view tracking disabled: ${err}`);
      }
    }

    // environment — only if an onConfigurationUpdated callback was supplied
    // (i.e. trackOrientationChanges is on).
    const envCb: ((config: SystemConfig) => void) | null = this.onConfigurationUpdated;
    if (envCb !== null) {
      try {
        const observer: CountlyEnvironmentObserver = new CountlyEnvironmentObserver(this.logger, envCb);
        const id: number = appCtx.on('environment', observer);
        this.envObserver = observer;
        this.envCallbackId = id;
        this.logger.d(`[LifecycleObserver] environment registered, id=${id}`);
      } catch (err) {
        this.logger.w(`[LifecycleObserver] environment.on failed — orientation auto-tracking disabled: ${err}`);
      }
    }
  }

  /**
   * Unsubscribe everything. Safe to call multiple times — no-op after the
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
      this.abilityObserver = null;
    }
    if (this.envCallbackId !== -1) {
      try { this.appContext.off('environment', this.envCallbackId); }
      catch (err) { this.logger.w(`[LifecycleObserver] deregister environment failed: ${err}`); }
      this.envCallbackId = -1;
      this.envObserver = null;
    }
    this.appContext = null;
  }

  /** Test/diagnostic helper. */
  public isRegistered(): boolean {
    return this.appStateObserver !== null;
  }
}
