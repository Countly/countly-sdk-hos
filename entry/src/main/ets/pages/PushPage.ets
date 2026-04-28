import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { Theme } from '../components/Theme';

/**
 * Push module is disabled in this build — the page is no longer registered in
 * `main_pages.json` and the matching tile is removed from the demo home, so
 * this file should be unreachable. The placeholder content stays so the file
 * keeps compiling (and so the page-load chrome stays consistent if the page
 * is reached via a deep-linked router URL during manual testing).
 */
@Entry
@Component
struct PushPage {
  build() {
    Column() {
      PageFrame({ title: 'Push', subtitle: 'module disabled' }) {
        SectionCard({ title: 'Disabled' }) {
          Text('Push notifications are disabled in this build. The CountlyInstance.push facade is private and the API class is not re-exported from the library.')
            .fontSize(13).fontColor(Theme.TEXT_MUTED).width('100%')
        }
      }
    }
    .width('100%').height('100%')
  }
}
