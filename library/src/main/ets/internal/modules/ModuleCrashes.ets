import errorManager from '@ohos.app.ability.errorManager';
import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { DeviceInfo } from '../DeviceInfo';
import { Utils } from '../Utils';
import { CountlyFeature, CrashData, SegmentationMap, ThreadStackEntry, ThreadStackProvider } from '../../types/Types';

const MAX_STACK_TRACE_CHARS: number = 20000;

interface CrashFieldChangedFlags {
  stack: boolean;
  segmentation: boolean;
  breadcrumbs: boolean;
  metrics: boolean;
  fatal: boolean;
}


function createCountlyErrorObserver(crashModule: ModuleCrashes): errorManager.ErrorObserver {
  return {
    onUnhandledException(errMsg: string): void {
      crashModule.handleUnhandledException(errMsg);
    },

    onException(errorObj: Error): void {
      crashModule.recordUnhandledException(errorObj, null);
    }
  };
}

/**
 * Crashes module. Handles:
 *   - Automatic uncaught-error reporting via HarmonyOS `errorManager`. When
 *     `enableCrashReporting` is on (default false), `onInit` registers a
 *     global ErrorObserver; the registration is torn down in `onHalt` so
 *     test instances don't leak observers across runs.
 *   - Manual handled/unhandled crash recording.
 *   - Breadcrumbs (in-memory only, not persisted).
 *   - Global crash filter callback with _ob bit calculation.
 */
export class ModuleCrashes extends ModuleBase {
  private core: SdkCore;
  private breadcrumbs: string[] = [];
  private appStartMs: number;
  private threadStackProvider: ThreadStackProvider | null = null;
  // One-time guard so the "flag on but no provider" warning fires when the
  // integrator is actually trying to record a crash, not on every breadcrumb
  // or module init. `true` = we've already warned this session.
  private missingProviderWarned: boolean = false;
  // Observer ID returned by `errorManager.on('error', ...)`. Tracked so
  // `onHalt` can pair it with `errorManager.off('error', id)`, without this,
  // each new ModuleCrashes (one per test) would leak an observer.
  private errorObserverId: number = -1;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleCrashes] Initialising');
    this.core = core;
    this.appStartMs = Date.now();
  }

  public override async onInit(): Promise<void> {
    if (this.config.enableCrashReporting) {
      this.installErrorHandler();
    }
  }

  /**
   * Optional hook for collecting Worker-thread stacks at crash time. Without
   * this, `recordAllThreadsWithCrash=true` can only ship the main-thread
   * stack (ArkTS isolates can't enumerate each other). Typical wiring:
   *
   *   countly.setThreadStackProvider(() => myWorkerRegistry.snapshotStacks());
   *
   * The SDK calls this synchronously during crash recording, keep it cheap
   * and non-throwing. A thrown error is caught and logged, then the crash
   * ships without extra thread info rather than being dropped.
   */
  public setThreadStackProvider(provider: ThreadStackProvider | null): void {
    if (this.rejectIfHalted('ModuleCrashes', 'setThreadStackProvider')) return;
    this.threadStackProvider = provider;
  }

  /**
   * Bridge from `CountlyErrorObserver.onUnhandledException` into the regular
   * record pipeline. The `errMsg` string already carries the full
   * "Name: message\nstack" payload that HarmonyOS synthesises for the
   * uncaught exception; we parse the head line to recover `name` and
   * `message`, then set `Error.stack` to the original payload so the
   * existing stack-normalisation in `recordInternal` is a pass-through.
   *
   * Public so the (non-exported) `CountlyErrorObserver` class above can
   * forward the callback, ArkTS will not let an outer class reach into a
   * `private` from a sibling class declared in the same file.
   */
  public handleUnhandledException(errMsg: string): void {
    if (this.rejectIfHalted('ModuleCrashes', 'handleUnhandledException')) return;
    const err: Error = ModuleCrashes.errorFromMessage(errMsg);
    // Log a rejection from the auto-handler path rather than swallowing it,
    // if crash recording fails (e.g. enqueue during OOM), the crash this
    // module exists to capture has been lost and the integrator needs to
    // know why.
    this.recordInternal(err, null, true).catch((recErr: Object) => {
      this.config.logger.e(`[ModuleCrashes] auto-record rejected: ${recErr}`);
    });
  }

  public addBreadcrumb(record: string): void {
    if (this.rejectIfHalted('ModuleCrashes', 'addBreadcrumb')) return;
    if (Utils.isNullOrEmpty(record)) {
      this.config.logger.w('[ModuleCrashes] addBreadcrumb, null/empty, ignored');
      return;
    }
    const truncated: string = Utils.truncate(record, this.config.limits.maxValueSize);
    this.breadcrumbs.push(truncated);
    while (this.breadcrumbs.length > this.config.limits.maxBreadcrumbCount) {
      this.breadcrumbs.shift();
    }
  }

  public async recordHandledException(err: Error, customSegmentation: SegmentationMap | null): Promise<void> {
    if (this.rejectIfHalted('ModuleCrashes', 'recordHandledException')) return;
    await this.recordInternal(err, customSegmentation, false);
  }

  public async recordUnhandledException(err: Error, customSegmentation: SegmentationMap | null): Promise<void> {
    if (this.rejectIfHalted('ModuleCrashes', 'recordUnhandledException')) return;
    await this.recordInternal(err, customSegmentation, true);
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    this.breadcrumbs = [];
  }

  public override async onHalt(): Promise<void> {
    if (this.errorObserverId !== -1) {
      try {
        errorManager.off('error', this.errorObserverId);
      } catch (e) {
        this.config.logger.w(`[ModuleCrashes] onHalt, errorManager.off failed: ${e}`);
      }
      this.errorObserverId = -1;
    }
  }

  private installErrorHandler(): void {
    if (this.errorObserverId !== -1) return;
    try {
      this.errorObserverId = errorManager.on('error', createCountlyErrorObserver(this));
      this.config.logger.d(`[ModuleCrashes] installErrorHandler, registered observer id=${this.errorObserverId}`);
    } catch (e) {
      // Don't fail SDK init because the platform refused the registration,
      // manual recordHandled/Unhandled paths still work without it.
      this.config.logger.w(`[ModuleCrashes] installErrorHandler, errorManager.on failed: ${e}`);
    }
  }

  /**
   * Parse the platform-supplied `errMsg` (a pre-formatted
   * "Name: message\nstack..." string) back into an `Error`. Sets `.stack` to
   * the full original payload so `recordInternal`'s "head already in stack"
   * fast path keeps the trace intact.
   */
  private static errorFromMessage(errMsg: string): Error {
    const safe: string = errMsg ? errMsg : 'UnhandledException';
    const newlineIdx: number = safe.indexOf('\n');
    const head: string = newlineIdx === -1 ? safe : safe.substring(0, newlineIdx);
    const colonIdx: number = head.indexOf(': ');
    let name: string = 'Error';
    let message: string = head;
    if (colonIdx > 0) {
      name = head.substring(0, colonIdx).trim();
      message = head.substring(colonIdx + 2).trim();
    }
    const err: Error = new Error(message);
    err.name = name;
    err.stack = safe;
    return err;
  }

  private async recordInternal(err: Error, customSegmentation: SegmentationMap | null, fatal: boolean): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.CRASHES)) return;
    // SDK Behavior Settings `crt` killswitch, server-side disable.
    if (!this.config.serverConfig.crashReportingEnabled) {
      this.config.logger.d('[ModuleCrashes] recordInternal, crash reporting disabled by server config, dropped');
      return;
    }
    if (!err) {
      this.config.logger.w('[ModuleCrashes] recordInternal, null error, ignored');
      return;
    }

    // Build stack trace string. Primary stack first, then (if enabled) any
    // Worker/background stacks the integrator provided. Per-thread line cap
    // is applied INSIDE appendThreadStacks so adding a second thread can't
    // truncate the first. capOverallStack enforces the final char ceiling.
    //
    // ArkTS's `Error.stack` is an unstable shape, sometimes it's just frames,
    // sometimes it has `Name: message` prepended. Filter callbacks and
    // server-side parsers both need the name+message reliably at the head, so
    // normalize: prepend the head only if the stack doesn't already carry it.
    const errName: string = err.name ? err.name : 'Error';
    const errMsg: string = err.message ? err.message : '';
    const head: string = errMsg.length > 0 ? `${errName}: ${errMsg}` : errName;
    const rawStack: string = err.stack ? err.stack : '';
    const normalized: string = rawStack.indexOf(head) !== -1
      ? rawStack
      : (rawStack.length > 0 ? `${head}\n${rawStack}` : head);
    let stack: string = this.truncatePerThread(normalized);
    stack = this.appendThreadStacks(stack);
    stack = this.capOverallStack(stack);

    // Merge global + per-call segmentation
    const mergedSeg: SegmentationMap = Utils.mergeMaps(
      this.config.customCrashSegmentation,
      customSegmentation ? customSegmentation : {}
    );
    const sanitizedSeg: SegmentationMap = Utils.sanitizeSegmentation(
      mergedSeg,
      this.config.limits.maxKeyLength,
      this.config.limits.maxValueSize,
      this.config.limits.maxSegmentationValues
    );

    const metrics: Record<string, Object> = {};
    const deviceMetrics: Record<string, string> = DeviceInfo.collect(this.config.appVersion, this.config.metricOverride);
    const keys: string[] = Object.keys(deviceMetrics);
    for (let i = 0; i < keys.length; i++) metrics[keys[i]] = deviceMetrics[keys[i]];
    metrics['_run'] = Math.round((Date.now() - this.appStartMs) / 1000);
    metrics['_background'] = false;

    const crashData: CrashData = new CrashData(
      stack,
      this.breadcrumbs.slice(),
      sanitizedSeg,
      metrics,
      fatal
    );

    // Snapshot for _ob computation
    const originalStack: string = crashData.stackTrace;
    const originalSeg: string = JSON.stringify(crashData.crashSegmentation);
    const originalBreadcrumbs: string = JSON.stringify(crashData.breadcrumbs);
    const originalMetrics: string = JSON.stringify(crashData.crashMetrics);
    const originalFatal: boolean = crashData.fatal;

    if (this.config.crashFilter) {
      try {
        const dropped: boolean = this.config.crashFilter(crashData);
        if (dropped) {
          this.config.logger.d('[ModuleCrashes] recordInternal, dropped by filter');
          return;
        }
      } catch (filterErr) {
        // A throwing filter is not the same as "filter not applied", we can't
        // know whether the filter had already redacted sensitive data before
        // throwing. Safer default: drop the crash. Integrators see a loud
        // ERROR so they can fix the filter without leaking unsanitized stacks.
        this.config.logger.e(`[ModuleCrashes] recordInternal, filter threw, dropping crash to avoid leaking unfiltered data: ${filterErr}`);
        return;
      }
    }

    // Recompute _ob from diffs
    const changed: CrashFieldChangedFlags = {
      stack: crashData.stackTrace !== originalStack,
      segmentation: JSON.stringify(crashData.crashSegmentation) !== originalSeg,
      breadcrumbs: JSON.stringify(crashData.breadcrumbs) !== originalBreadcrumbs,
      metrics: JSON.stringify(crashData.crashMetrics) !== originalMetrics,
      fatal: crashData.fatal !== originalFatal
    };
    const ob: number = ModuleCrashes.computeOb(changed);

    // Re-apply limits after filtering (dev guide requirement). Per-line
    // length cap plus overall char ceiling always run; per-thread section
    // cap does NOT re-run because the filter may have legitimately re-
    // stitched Thread sections (double-truncating would corrupt them).
    const finalStack: string = this.capOverallStack(this.enforcePerLineCap(crashData.stackTrace));
    const finalSeg: SegmentationMap = Utils.sanitizeSegmentation(
      crashData.crashSegmentation,
      this.config.limits.maxKeyLength,
      this.config.limits.maxValueSize,
      this.config.limits.maxSegmentationValues
    );
    // Take the LAST maxBreadcrumbCount entries, a filter that pushes new
    // breadcrumbs past the cap should ship the most recent ones, not the
    // oldest. Mirrors the rotate-on-add behavior (oldest dropped first).
    const cap: number = this.config.limits.maxBreadcrumbCount;
    const finalBreadcrumbs: string[] = crashData.breadcrumbs.length <= cap
      ? crashData.breadcrumbs.slice()
      : crashData.breadcrumbs.slice(crashData.breadcrumbs.length - cap);

    const crashObj: Record<string, Object> = {};
    const metricKeys: string[] = Object.keys(crashData.crashMetrics);
    for (let i = 0; i < metricKeys.length; i++) crashObj[metricKeys[i]] = crashData.crashMetrics[metricKeys[i]];
    crashObj['_error'] = finalStack;
    crashObj['_nonfatal'] = !crashData.fatal;
    crashObj['_logs'] = finalBreadcrumbs.join('\n');
    crashObj['_custom'] = finalSeg as Object;
    crashObj['_ob'] = ob;

    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['crash'] = JSON.stringify(crashObj);
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
    // INFO, first line of evidence that a crash actually reached the queue.
    // The `ob` bit flags whether the filter mutated anything, which is the
    // most common diagnostic question when filters are wired.
    this.config.logger.i(`[ModuleCrashes] recordInternal, enqueued fatal=${crashData.fatal} stackChars=${finalStack.length} breadcrumbs=${finalBreadcrumbs.length} ob=${ob}`);
  }

  /**
   * Append Worker/background-thread stacks to the primary stack trace when
   * `recordAllThreadsWithCrash` is enabled. If no provider is wired we log a
   * one-time warning (not per-crash, that would drown the log listener
   * during a crash loop) so integrators notice the flag is effectively inert.
   * Returns the original stack unchanged when the flag is off or the provider
   * yields nothing.
   */
  private appendThreadStacks(primaryStack: string): string {
    if (!this.config.recordAllThreadsWithCrash) return primaryStack;
    if (!this.threadStackProvider) {
      if (!this.missingProviderWarned) {
        this.missingProviderWarned = true;
        this.config.logger.w('[ModuleCrashes] recordAllThreadsWithCrash is enabled but no threadStackProvider is wired, ArkTS isolates cannot enumerate Worker stacks from the main thread. Call Countly.setThreadStackProvider(...) to include them, or disable the flag to silence this warning.');
      }
      return primaryStack;
    }
    let extras: ThreadStackEntry[];
    try {
      extras = this.threadStackProvider();
    } catch (providerErr) {
      // Crash-time code path, never let the provider's error mask the real
      // crash. Log and fall back to the main stack only.
      this.config.logger.e(`[ModuleCrashes] threadStackProvider threw: ${providerErr}, shipping crash without extra thread info`);
      return primaryStack;
    }
    if (!extras || extras.length === 0) return primaryStack;

    const maxThreads: number = this.config.limits.maxStackTraceThreadCount;
    let out: string = primaryStack;
    let added: number = 0;
    for (let i = 0; i < extras.length && added < maxThreads; i++) {
      const entry: ThreadStackEntry = extras[i];
      if (!entry || !entry.name || !entry.stack) continue;
      // Wire format: blank line, "Thread <name>", then stack lines. Cap
      // each thread's stack at maxStackTraceLinesPerThread individually so
      // one runaway Worker can't starve subsequent threads of budget.
      const truncated: string = this.truncatePerThread(entry.stack);
      out += `\n\nThread ${entry.name}\n${truncated}`;
      added++;
    }
    return out;
  }

  /**
   * Enforce per-thread line count + per-line length on a single stack
   * trace. Used for both the primary stack and each Worker section so
   * limits are consistent across the whole payload.
   */
  private truncatePerThread(stack: string): string {
    if (!stack) return '';
    const lines: string[] = stack.split('\n');
    const maxLines: number = this.config.limits.maxStackTraceLinesPerThread;
    const maxLineLen: number = this.config.limits.maxStackTraceLineLength;
    const kept: string[] = [];
    for (let i = 0; i < lines.length && kept.length < maxLines; i++) {
      kept.push(Utils.truncate(lines[i], maxLineLen));
    }
    return kept.join('\n');
  }

  /**
   * Final char-ceiling for the whole crash payload, protects against
   * pathological Worker stacks pushing the request past sane wire sizes.
   * Per-line and per-thread caps already ran upstream.
   */
  private capOverallStack(stack: string): string {
    if (!stack) return '';
    return stack.length > MAX_STACK_TRACE_CHARS ? stack.substring(0, MAX_STACK_TRACE_CHARS) : stack;
  }

  /**
   * Per-line length cap only, no line count restriction. Used after the
   * crash filter runs so integrator edits that rearranged existing
   * sections aren't double-truncated, while lone runaway lines still get
   * clipped to the configured per-line maximum.
   */
  private enforcePerLineCap(stack: string): string {
    if (!stack) return '';
    const maxLineLen: number = this.config.limits.maxStackTraceLineLength;
    const lines: string[] = stack.split('\n');
    const out: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      out.push(Utils.truncate(lines[i], maxLineLen));
    }
    return out.join('\n');
  }

  private static computeOb(changed: CrashFieldChangedFlags): number {
    let bits: number = 0;
    if (changed.stack) bits |= 16;
    if (changed.segmentation) bits |= 8;
    if (changed.breadcrumbs) bits |= 4;
    if (changed.metrics) bits |= 2;
    if (changed.fatal) bits |= 1;
    return bits;
  }
}
