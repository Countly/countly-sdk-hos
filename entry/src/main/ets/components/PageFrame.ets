import router from '@ohos.router';
import { CountlyOverlayRoot } from 'countly-sdk-hos';
import { LogPanel } from './LogPanel';
import { Theme } from './Theme';

/**
 * Uniform page chrome: dark header with back button + title, scrollable body
 * from the caller, and a log panel pinned to the bottom. Consumers place
 * their per-feature controls inside the trailing `{ ... }` block.
 */
@Component
export struct PageFrame {
  title: string = '';
  subtitle: string = '';
  // ArkTS strict: `@BuilderParam` default must be a `@Builder` function or
  // `@LocalBuilder` method — a plain arrow is rejected. Omitting the default
  // forces callers to always supply the trailing body block, which every
  // consumer already does.
  @BuilderParam body: () => void;

  build() {
    // Stack wrapper hosts the normal page chrome plus the SDK-rendered
    // overlay. CountlyOverlayRoot() is the ONE line the integrator needs to
    // enable Content Zone + Feedback widget rendering — it sits transparent
    // above the whole page and only mounts a Web component when the SDK
    // publishes overlay state.
    Stack() {
      Column() {
        // Header
        Column() {
          Row() {
            Text('‹')
              .fontSize(28)
              .fontColor(Theme.TEXT_INVERT)
              .fontWeight(FontWeight.Bold)
              .width(36)
              .height(36)
              .textAlign(TextAlign.Center)
              .onClick(() => { router.back(); })
            Column() {
              Text(this.title)
                .fontSize(18)
                .fontColor(Theme.TEXT_INVERT)
                .fontWeight(FontWeight.Bold)
                .width('100%')
                .textAlign(TextAlign.Start)
              if (this.subtitle.length > 0) {
                Text(this.subtitle)
                  .fontSize(11)
                  .fontColor('#94A3B8')
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .margin({ top: 2 })
              }
            }
            .layoutWeight(1)
            .padding({ left: 6 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 18, bottom: 14 })
        .backgroundColor(Theme.HEADER)

        // Body
        Scroll() {
          Column() {
            this.body()
            Blank().height(8)
          }
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 14, right: 14, top: 14 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .backgroundColor(Theme.BG)
        .align(Alignment.TopStart)
        .width('100%')

        // Log
        LogPanel()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.BG)

      // SDK-rendered overlay. Transparent when no Content / Feedback state
      // is active; mounts a Web component when the SDK publishes.
      CountlyOverlayRoot()
    }
    .width('100%')
    .height('100%')
  }
}
