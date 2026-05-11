import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { Theme } from '../components/Theme';
import { LogPanel } from '../components/LogPanel';
import { DemoLog } from '../model/DemoState';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

/**
 * Page hosted by `TertiaryAbility`. Mirror of `SecondaryPage` — see that file
 * for the rationale on why we sidestep `PageFrame`'s router-based back
 * arrow in favour of an explicit `terminateSelf()` button.
 */
@Entry
@Component
struct TertiaryPage {
  private terminate = (): Promise<void> => DemoLog.safe('TertiaryAbility.terminateSelf', (): Promise<void> | void => {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!ctx) {
      hilog.warn(DOMAIN, TAG, '[Demo] TertiaryPage: no UIAbilityContext available');
      return;
    }
    return ctx.terminateSelf();
  });

  build() {
    Column() {
      Column() {
        Text('TertiaryAbility')
          .fontSize(24)
          .fontColor(Theme.TEXT_INVERT)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('auto-view target #2 — expect [CLY]_view name=TertiaryAbility')
          .fontSize(11)
          .fontColor('#94A3B8')
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 6 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 20 })
      .backgroundColor(Theme.HEADER)
      .alignItems(HorizontalAlign.Start)

      Column() {
        Button('Back to Entry')
          .fontSize(14)
          .fontColor(Theme.TEXT_INVERT)
          .backgroundColor('#7C3AED')
          .type(ButtonType.Normal)
          .borderRadius(Theme.RADIUS_MD)
          .height(42)
          .width('100%')
          .onClick(() => { this.terminate(); })
      }
      .width('100%')
      .padding(14)
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      LogPanel()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
