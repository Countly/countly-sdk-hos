import { DemoLog, StoreKeys } from '../model/DemoState';
import { Theme } from './Theme';

/**
 * Collapsible log panel. Reads from AppStorage[StoreKeys.LOG] so every page
 * sees the same history as soon as it mounts. Newest entry on top.
 */
@Component
export struct LogPanel {
  @StorageLink('demo_log') log: string[] = [];
  // @StorageLink (not @State) so the collapse state survives navigation —
  // each page creates a fresh LogPanel, so @State would reset to true on
  // every push/back.
  @StorageLink('demo_log_expanded') expanded: boolean = true;

  build() {
    Column() {
      Row() {
        Text(`Log  (${this.log.length})`)
          .fontSize(12)
          .fontColor(Theme.LOG_MUTED)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text('clear')
          .fontSize(12)
          .fontColor(Theme.LOG_MUTED)
          .padding({ left: 8, right: 8 })
          .onClick(() => { DemoLog.clear(); })
        Text(this.expanded ? 'hide' : 'show')
          .fontSize(12)
          .fontColor(Theme.LOG_MUTED)
          .padding({ left: 8, right: 8 })
          .onClick(() => { this.expanded = !this.expanded; })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 6 })

      if (this.expanded) {
        Scroll() {
          Column() {
            if (this.log.length === 0) {
              Text('— nothing yet —')
                .fontSize(11)
                .fontColor(Theme.LOG_MUTED)
                .width('100%')
                .padding({ left: 12, right: 12, top: 4, bottom: 8 })
            } else {
              ForEach(this.log, (line: string) => {
                Text(line)
                  .fontSize(11)
                  .fontColor(Theme.LOG_TEXT)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .padding({ left: 12, right: 12, top: 2, bottom: 2 })
              }, (line: string, index: number) => `${index}:${line}`)
            }
          }
          .alignItems(HorizontalAlign.Start)
        }
        .scrollBar(BarState.Auto)
        .height(160)
        .backgroundColor(Theme.LOG_BG)
      }
    }
    .width('100%')
    .backgroundColor(Theme.LOG_BG)
  }
}
