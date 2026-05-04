import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

/**
 * Countly SDK initialisation lives in `MyAbilityStage` (see
 * `entry/src/main/ets/myabilitystage/MyAbilityStage.ets`), which runs once
 * per HAP module process BEFORE this ability is created. Initialising at the
 * stage level means the SDK's `applicationStateChange` and `abilityLifecycle`
 * subscriptions are registered before the platform fires the first
 * foreground transition, so the cold-boot session and auto-view are captured
 * cleanly.
 *
 * As a result, this UIAbility intentionally has no SDK-related code: no
 * `Countly.initShared` call, no `onForeground` / `onBackground` overrides
 * (the SDK auto-subscribes from MyAbilityStage). The lifecycle methods below
 * exist only to load the page and emit hilog breadcrumbs.
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
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
}
