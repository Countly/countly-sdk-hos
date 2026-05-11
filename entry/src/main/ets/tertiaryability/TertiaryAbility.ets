import UIAbility from '@ohos.app.ability.UIAbility';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import Want from '@ohos.app.ability.Want';
import window from '@ohos.window';
import hilog from '@ohos.hilog';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

/**
 * Second auxiliary UIAbility — see `SecondaryAbility.ets` for the rationale.
 * Having a third distinct ability lets the demo confirm consecutive
 * auto-view transitions: Entry -> Secondary -> Tertiary -> Entry, each fg
 * transition emits one `[CLY]_view` event with the corresponding ability
 * name.
 */
export default class TertiaryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '[Demo] TertiaryAbility onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, '[Demo] TertiaryAbility onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/TertiaryPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `TertiaryAbility loadContent failed: ${JSON.stringify(err)}`);
        return;
      }
      hilog.info(DOMAIN, TAG, '[Demo] TertiaryAbility loadContent OK');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, '[Demo] TertiaryAbility onWindowStageDestroy');
  }
}
