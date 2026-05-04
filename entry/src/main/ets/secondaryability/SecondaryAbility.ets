import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

/**
 * Auxiliary UIAbility used purely to exercise the SDK's automatic view
 * tracking path. The SDK subscribes to `abilityLifecycle.onAbilityForeground`
 * (registered in `MyAbilityStage.onCreate` via the SDK's init), and the
 * platform fires that event ONLY on a UIAbility transition — not on
 * `router.pushUrl` between pages of a single ability. This ability exists so
 * the demo can transition between distinct abilities and observe
 * `[CLY]_view` events in the HiLog stream with `name=SecondaryAbility`.
 *
 * No SDK code lives here: SDK init runs once in `MyAbilityStage.onCreate`
 * before any UIAbility is created, and lifecycle observers are auto-wired
 * (see memory `project_auto_lifecycle.md`). Mirrors `EntryAbility.ets`.
 */
export default class SecondaryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '[Demo] SecondaryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '[Demo] SecondaryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/SecondaryPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `SecondaryAbility loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      hilog.info(DOMAIN, TAG, '[Demo] SecondaryAbility loadContent OK');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '[Demo] SecondaryAbility onWindowStageDestroy');
  }
}
