import { LogLevel, LogListener } from '../types/Types';

/**
 * Internal callback for ModuleHealthCheck, fires on every WARNING/ERROR
 * log. A named type alias (rather than inline function type) keeps ArkTS
 * strict mode happy with the nominal-typing rules on class fields.
 */
export type HealthLogListener = (isError: boolean) => void;

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

  public setHealthListener(listener: HealthLogListener | null): void {
    this.healthListener = listener;
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
    const formatted: string = `[Countly] ${message}`;

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
          console.error(`[Countly] log listener threw: ${err}, subsequent listener errors will be suppressed`);
        }
      }
    }
  }
}
