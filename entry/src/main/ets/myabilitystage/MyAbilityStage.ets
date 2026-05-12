import AbilityStage from '@ohos.app.ability.AbilityStage';
import hilog from '@ohos.hilog';
import {
  Countly,
  CountlyConfig,
  LogLevel
} from 'countly-sdk-hos';
import { DemoLog, StoreKeys } from '../model/DemoState';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

// Fill these in before running. COUNTLY_SERVER_URL must be an https:// URL of a
// Countly server you control (or a trial server from trial.count.ly).
const COUNTLY_SERVER_URL: string = 'YOUR_SERVER_URL';
const COUNTLY_APP_KEY: string = 'YOUR_APP_KEY';

/**
 * AbilityStage runs ONCE per HAP module process, BEFORE any UIAbility is
 * created. This is the HMOS equivalent of Android's Application class and the
 * recommended init point for the SDK: registering the lifecycle observers
 * here guarantees they're live before the platform fires the first ability's
 * foreground transitions, eliminating the cold-boot race that otherwise
 * causes the very first session and auto-view to be silently dropped.
 *
 * Wired via `module.json5` -> "srcEntry" at the module level.
 *
 * Two HMOS-specific notes:
 *   1. `onCreate()` returns void — the platform does not await it. We
 *      fire-and-forget the async init and surface readiness via AppStorage
 *      so pages can react via @StorageLink.
 *   2. `this.context` is an AbilityStageContext, NOT a UIAbilityContext.
 *      Sessions, views, events and storage all work fine off it. The
 *      external-URL-opener path used by Content / Feedback (currently
 *      disabled in this build) needs `startAbility`, which lives on
 *      UIAbilityContext only — re-enable that path by calling
 *      `setExternalUrlOpener(...)` from a UIAbility's `onForeground`.
 */
export default class MyAbilityStage extends AbilityStage {
  onCreate(): void {
    hilog.info(DOMAIN, TAG, 'MyAbilityStage onCreate');

    // Publish readiness BEFORE kicking off init so the very first @StorageLink
    // read in Index sees an explicit `false` rather than `undefined`.
    AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, false);
    this.initCountly().catch((err: Object) => {
      hilog.error(DOMAIN, TAG, `Countly init promise rejected: ${err}`);
    });
  }

  private async initCountly(): Promise<void> {
    const config: CountlyConfig = new CountlyConfig(this.context, COUNTLY_SERVER_URL, COUNTLY_APP_KEY)
      .setAppVersion('1.0.0');

    config.logging
      .enableLogging()
      .setMinLevel(LogLevel.VERBOSE)
      .setListener((msg: string, level: LogLevel) => {
        // Two consumers: DevEco's HiLog window (filter on tag "CountlyDemo"),
        // and the on-screen LogPanel so you can read SDK internals without
        // leaving the device. Gate at INFO so fetch lifecycle lines surface.
        hilog.info(DOMAIN, TAG, `[sdk:${level}] ${msg}`);
        if (level >= LogLevel.INFO) {
          DemoLog.append(msg);
        }
      });

    // Start with all consents granted so every demo button works out of the
    // box. In a real app you would gate these behind a consent flow.
    config.consent
      .setRequiresConsent(true)
      .giveAll();

    config.crashes.enableCrashReporting();
    config.views.enableAutomaticViewTracking();

    try {
      await Countly.initShared(config);
      hilog.info(DOMAIN, TAG, 'Countly initShared OK');
      AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, true);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Countly initShared failed: ${e}`);
      AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, false);
    }
  }
}
