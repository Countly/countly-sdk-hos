import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { Theme } from '../components/Theme';
import { LogPanel } from '../components/LogPanel';
import { DemoLog } from '../model/DemoState';

const TAG: string = 'CountlyDemo';
const DOMAIN: number = 0xC047;

/**
 * Page hosted by `SecondaryAbility`. Intentionally barebones: a header and a
 * single "Back to Entry" action that terminates this UIAbility, which causes
 * the platform to bring `EntryAbility` back to the foreground and (because
 * automatic view tracking is enabled) emit a `[CLY]_view` event with
 * `name=EntryAbility`.
 *
 * NOTE on PageFrame: the shared `PageFrame` component renders a back arrow
 * that calls `router.back()` — that pops within the current UIAbility's page
 * stack and is a no-op when the ability has only one page. We avoid
 * PageFrame here so the only navigation control is the explicit
 * "Back to Entry" button that calls `terminateSelf()` on the ability
 * context, which is the actual cross-ability transition we want to exercise.
 */
@Entry
@Component
struct SecondaryPage {
  private terminate = (): Promise<void> => DemoLog.safe('SecondaryAbility.terminateSelf', (): Promise<void> | void => {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!ctx) {
      hilog.warn(DOMAIN, TAG, '[Demo] SecondaryPage: no UIAbilityContext available');
      return;
    }
    return ctx.terminateSelf();
  });

  build() {
    Column() {
      Column() {
        Text('SecondaryAbility')
          .fontSize(24)
          .fontColor(Theme.TEXT_INVERT)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('auto-view target #1 — expect [CLY]_view name=SecondaryAbility')
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
          .backgroundColor('#2563EB')
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
