import { Theme } from './Theme';

/**
 * Labeled single-line text input. Uses a two-way binding via `$$` syntax so
 * the owning component's @State updates automatically.
 */
@Component
export struct InputField {
  label: string = '';
  placeholder: string = '';
  @Link value: string;
  keyboardType: InputType = InputType.Normal;

  build() {
    Column() {
      if (this.label.length > 0) {
        Text(this.label)
          .fontSize(12)
          .fontColor(Theme.TEXT_MUTED)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 4 })
      }
      TextInput({ text: this.value, placeholder: this.placeholder })
        .type(this.keyboardType)
        .fontSize(14)
        .fontColor(Theme.TEXT)
        .placeholderColor(Theme.TEXT_MUTED)
        .backgroundColor(Theme.CARD)
        .border({ width: 1, color: Theme.BORDER, radius: Theme.RADIUS_MD })
        .borderRadius(Theme.RADIUS_MD)
        .height(40)
        .padding({ left: 12, right: 12 })
        .onChange((v: string): void => { this.value = v; })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: 10 })
  }
}
