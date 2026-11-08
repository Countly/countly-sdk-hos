import { LogLevel, LogListener } from '../types/Types';

/**
 * Internal callback for ModuleHealthCheck, fires on every WARNING/ERROR
 * log. A named type alias (rather than inline function type) keeps ArkTS
 * strict mode happy with the nominal-typing rules on class fields.
 */
export type HealthLogListener = (isError: boolean) => void;

/** Internal callback for ModuleHealthCheck, fires for every health check log code (see `healthCode`). */
export type HealthCodeListener = (code: string, area: string) => void;

/** Internal callback for ModuleHealthCheck, fires for every counted method call (see `healthUsage`). */
export type HealthUsageListener = (area: string, method: string) => void;

/**
 * Log output. The "flag" enables console output; the "listener" enables a
 * side-channel callback. Both are independent so integrators can get logs
 * in release builds without printing to the system console.
 */
export class Logger {
  private enabled: boolean = false;
  private listener: LogListener | null = null;
  private minLevel: LogLevel = LogLevel.DEBUG;
  private listenerErrorReported: boolean = false;
  private healthListener: HealthLogListener | null = null;
  private healthCodeListener: HealthCodeListener | null = null;
  private healthUsageListener: HealthUsageListener | null = null;
  /** True while an automatically detected crash is reported, see `setHealthPaused`. */
  private healthPaused: boolean = false;
  // Counted for the health check before ModuleHealthCheck listened, handed over when it does.
  private pendingWarnings: number = 0;
  private pendingErrors: number = 0;
  private pendingCodes: string[] = [];
  /**
   * Optional named-instance suffix appended to the brand prefix:
   * `[Countly]` for the shared instance, `[Countly:foo]` for an
   * instance created via `Countly.createInstance('foo', ...)`. Set
   * once by `createInstance` after the per-instance Logger is built
   * so all subsequent log lines (including listener-side) can be
   * disambiguated when multiple instances run in the same process.
   */
  private instanceName: string = '';

  /**
   * Hands every WARNING/ERROR log to ModuleHealthCheck. The ones logged
   * before it listened are handed over now.
   */
  public setHealthListener(listener: HealthLogListener | null): void {
    this.healthListener = listener;
    if (listener === null) return;
    for (let i = 0; i < this.pendingWarnings; i++) listener(false);
    for (let i = 0; i < this.pendingErrors; i++) listener(true);
    this.pendingWarnings = 0;
    this.pendingErrors = 0;
  }

  /**
   * Hands every health check log code to ModuleHealthCheck. The codes
   * recorded before it listened are handed over now.
   */
  public setHealthCodeListener(listener: HealthCodeListener | null): void {
    this.healthCodeListener = listener;
    if (listener === null) return;
    const pending: string[] = this.pendingCodes;
    this.pendingCodes = [];
    for (let i = 0; i < pending.length; i++) listener(pending[i], '');
  }

  /** Hands every counted method call to ModuleHealthCheck. */
  public setHealthUsageListener(listener: HealthUsageListener | null): void {
    this.healthUsageListener = listener;
  }

  /**
   * Holds back method usage and log codes while an automatically detected
   * crash is reported, so the crash report never calls into the health check.
   */
  public setHealthPaused(paused: boolean): void {
    this.healthPaused = paused;
  }

  /**
   * Counts a known problem for the health check, next to the log line that
   * reports it (dev guide §Health Checks, log codes). A code that a method
   * of a feature area records passes the area ('sessions', 'events', 'views'
   * or 'crashes') and is counted only while that feature has consent.
   */
  public healthCode(code: string, area: string = ''): void {
    if (this.healthPaused) return;
    if (this.healthCodeListener !== null) {
      this.healthCodeListener(code, area);
    } else {
      this.pendingCodes.push(code);
    }
  }

  /**
   * Counts a call of a session, event, view or crash method for the health
   * check (dev guide §Health Checks, method usage), with ':a' for a call
   * the SDK made by itself.
   */
  public healthUsage(area: string, method: string): void {
    if (this.healthPaused || this.healthUsageListener === null) return;
    this.healthUsageListener(area, method);
  }

  public setInstanceName(name: string): void {
    this.instanceName = name;
  }

  public setEnabled(enabled: boolean): void {
    this.enabled = enabled;
  }

  public setListener(listener: LogListener | null): void {
    this.listener = listener;
    this.listenerErrorReported = false;
  }

  public setMinLevel(level: LogLevel): void {
    this.minLevel = level;
  }

  public v(msg: string): void { this.log(LogLevel.VERBOSE, msg); }
  public d(msg: string): void { this.log(LogLevel.DEBUG, msg); }
  public i(msg: string): void { this.log(LogLevel.INFO, msg); }
  public w(msg: string): void { this.log(LogLevel.WARNING, msg); }
  public e(msg: string): void { this.log(LogLevel.ERROR, msg); }

  private log(level: LogLevel, message: string): void {
    // Notify the health-check listener BEFORE the minLevel filter so diagnostic
    // counters are accurate even when the integrator has raised minLevel to
    // suppress noise. Error/warning-only to match the dev guide spec.
    if (this.healthListener !== null) {
      if (level === LogLevel.ERROR) this.healthListener(true);
      else if (level === LogLevel.WARNING) this.healthListener(false);
    } else if (level === LogLevel.ERROR) {
      this.pendingErrors++;
    } else if (level === LogLevel.WARNING) {
      this.pendingWarnings++;
    }

    // Both the console and the listener now honor minLevel. If the integrator
    // wants more verbose logs in their listener, they should lower minLevel
    // explicitly, routing VERBOSE keys/values to any wired-up cloud logger
    // by default is a data-exfiltration hazard.
    if (level < this.minLevel) return;

    // No level tag in the message itself, the console method (and hilog,
    // which `console.*` ultimately routes to on HMOS) already carries the
    // severity. Adding `[Debug]`/`[Info]`/etc. produced "I [Debug] ..."
    // double-tagged lines in hilog. Listeners that want the level get it
    // via the second arg.
    // Named instances get a `:name` suffix on the brand so concurrent
    // instances are distinguishable in a shared hilog tail. Shared
    // instance keeps the unadorned `[Countly]` for backwards-compat
    // with existing hilog grep filters.
    const brand: string = this.instanceName.length > 0
      ? `[Countly:${this.instanceName}]`
      : '[Countly]';
    const formatted: string = `${brand} ${message}`;

    if (this.enabled) {
      // HarmonyOS console routes through hilog under the hood with severity
      // matched per method, console.error → E, .warn → W, .info → I, .debug
      // → D, .log → I (same as info). VERBOSE has no console equivalent so
      // it maps to .debug.
      switch (level) {
        case LogLevel.ERROR:
          console.error(formatted);
          break;
        case LogLevel.WARNING:
          console.warn(formatted);
          break;
        case LogLevel.INFO:
          console.info(formatted);
          break;
        case LogLevel.DEBUG:
        case LogLevel.VERBOSE:
          console.debug(formatted);
          break;
        default:
          console.log(formatted);
      }
    }

    if (this.listener) {
      try {
        this.listener(formatted, level);
      } catch (err) {
        // Surface a misconfigured listener once via console.error, but never
        // recurse through log(), that'd be infinite if listener wraps us.
        if (!this.listenerErrorReported) {
          this.listenerErrorReported = true;
          console.error(`${brand} log listener threw: ${err}, subsequent listener errors will be suppressed`);
        }
      }
    }
  }
}
