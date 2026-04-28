import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import {
  Countly,
  CountlyConfig,
  ContentStatus,
  LogLevel,
  CountlyFeatureNames,
  WebViewDisplayOption
} from 'countly-sdk-hos';
import { DemoLog, StoreKeys } from '../model/DemoState';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

// Fill these in before running. COUNTLY_SERVER_URL must be an https:// URL of a
// Countly server you control (or a trial server from trial.count.ly).
const COUNTLY_SERVER_URL: string = 'https://master.count.ly';
const COUNTLY_APP_KEY: string = 'sdk_qa_test';

export default class EntryAbility extends UIAbility {
  async onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): Promise<void> {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');

    const config: CountlyConfig = new CountlyConfig(this.context, COUNTLY_SERVER_URL, COUNTLY_APP_KEY)
      .setAppVersion('1.0.0');

    config.logging
      .enableLogging()
      .setMinLevel(LogLevel.VERBOSE)
      .setListener((msg: string, level: LogLevel) => {
        // Two consumers: DevEco's HiLog window (filter on tag "CountlyDemo"),
        // and the on-screen LogPanel so you can read SDK internals without
        // leaving the device.
        //
        // Gate at INFO (not WARNING) so fetch lifecycle — e.g. Content Zone's
        // "fetchContents, response had no valid content payload" — shows up
        // on screen. That line is the most likely "why did nothing appear?"
        // diagnostic, and at WARNING it would stay invisible.
        hilog.info(DOMAIN, TAG, `[sdk:${level}] ${msg}`);
        if (level >= LogLevel.INFO) {
          DemoLog.append(msg);
        }
      });

    // Start with all consents granted so every demo button works out of the
    // box. In a real app you would gate these behind a consent flow.
    config.consent
      .setRequiresConsent(true)
      .setEnabled(CountlyFeatureNames);

    // Enable optional features via the sub-configs.
    config.crashes.enableCrashReporting();
    config.views.enableAutomaticViewTracking();

    // Content + Feedback overlays are rendered entirely by the SDK via
    // `CountlyOverlayRoot()` mounted in `PageFrame`. This callback wires only
    // the global content lifecycle hook (visible in hilog for debugging).
    config.content
      .setDisplayMode(WebViewDisplayOption.SAFE_AREA)
      .setZoneTimerInterval(16) // just above the 15s minimum so the demo loops quickly
      .setContentCallback((status: ContentStatus, data: Record<string, Object>) => {
        hilog.info(DOMAIN, TAG, `[ContentCallback] status=${status} data=${JSON.stringify(data)}`);
      });

    // Publish readiness via AppStorage. HarmonyOS does not await async
    // onCreate before onWindowStageCreate, so Index renders while init is
    // still in flight — a @StorageLink on this key makes the header status
    // line flip from "initializing" to "ready" as soon as init resolves.
    AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, false);
    try {
      await Countly.initShared(config);
      hilog.info(DOMAIN, TAG, 'Countly initShared OK');
      // External URL opening (content action=link, feedback cly_x_int=1) is
      // handled automatically by the SDK using the UIAbilityContext passed
      // via `new CountlyConfig(this.context, ...)`. Integrators only need
      // to call `setExternalUrlOpener(...)` to override with a custom
      // router (in-app browser, deep-link dispatcher, etc.).
      AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, true);
    } catch (e) {
      hilog.error(DOMAIN, TAG, `Countly initShared failed: ${e}`);
      AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, false);
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent OK');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onWindowStageDestroy');
  }

  // No onForeground / onBackground overrides — the SDK auto-subscribes to
  // ApplicationContext's `applicationStateChange` event during init and
  // routes fg/bg into every active CountlyInstance automatically. To
  // override (e.g., for tests or non-standard ability hosts), call
  // `Countly.lifecycleForegroundAll()` / `lifecycleBackgroundAll()`
  // directly — those statics still exist for manual driving.
}
