import { Theme } from './Theme';

/**
 * Card wrapper with a title and an arbitrary body. Consumers place their
 * controls inside the trailing `{ ... }` block which fills the `body`
 * BuilderParam slot.
 */
@Component
export struct SectionCard {
  title: string = '';
  subtitle: string = '';
  // ArkTS strict: `@BuilderParam` default must be a `@Builder`/`@LocalBuilder`.
  // No default → callers must always provide the trailing body block.
  @BuilderParam body: () => void;

  build() {
    Column() {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.TEXT)
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      if (this.subtitle.length > 0) {
        Text(this.subtitle)
          .fontSize(12)
          .fontColor(Theme.TEXT_MUTED)
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 2, bottom: 8 })
      } else if (this.title.length > 0) {
        Blank().height(8)
      }
      Column() {
        this.body()
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .margin({ bottom: 12 })
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS_LG)
    .border({ width: 1, color: Theme.BORDER })
  }
}
