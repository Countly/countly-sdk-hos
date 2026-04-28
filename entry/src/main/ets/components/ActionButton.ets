import { ButtonTone, Theme, ToneResolver } from './Theme';

/**
 * Styled action button. Accepts a click handler that may return void or a
 * Promise — any rejection is swallowed (the handler is expected to route
 * errors through DemoLog.safe so the log panel shows them).
 */
@Component
export struct ActionButton {
  label: string = '';
  tone: ButtonTone = ButtonTone.Primary;
  stretch: boolean = false;
  onAction: () => Promise<void> | void = () => {};

  build() {
    Button(this.label)
      .fontSize(13)
      .fontColor(Theme.TEXT_INVERT)
      .fontWeight(FontWeight.Medium)
      .backgroundColor(ToneResolver.bg(this.tone))
      .type(ButtonType.Normal)
      .borderRadius(Theme.RADIUS_MD)
      .height(38)
      .layoutWeight(this.stretch ? 1 : 0)
      .margin({ right: 6, bottom: 6 })
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        const r: Promise<void> | void = this.onAction();
        if (r instanceof Promise) r.catch((): void => { /* DemoLog.safe already logged */ });
      })
  }
}

/**
 * Outline variant for destructive or secondary actions where a filled look
 * would be visually loud.
 */
@Component
export struct GhostButton {
  label: string = '';
  stretch: boolean = false;
  onAction: () => Promise<void> | void = () => {};

  build() {
    Button(this.label)
      .fontSize(13)
      .fontColor(Theme.TEXT)
      .fontWeight(FontWeight.Medium)
      .backgroundColor(Theme.CARD)
      .type(ButtonType.Normal)
      .borderRadius(Theme.RADIUS_MD)
      .border({ width: 1, color: Theme.BORDER })
      .height(38)
      .layoutWeight(this.stretch ? 1 : 0)
      .margin({ right: 6, bottom: 6 })
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        const r: Promise<void> | void = this.onAction();
        if (r instanceof Promise) r.catch((): void => {});
      })
  }
}
