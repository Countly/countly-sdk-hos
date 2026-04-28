import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { Theme } from '../components/Theme';

/**
 * Content Zone module is disabled in this build — the page is no longer
 * registered in `main_pages.json` and the matching tile is removed from the
 * demo home, so this file should be unreachable. The placeholder content
 * stays so the file keeps compiling.
 */
@Entry
@Component
struct ContentZonePage {
  build() {
    Column() {
      PageFrame({ title: 'Content Zone', subtitle: 'module disabled' }) {
        SectionCard({ title: 'Disabled' }) {
          Text('Content Zone is disabled in this build. The CountlyInstance.content facade is private and the API class is not re-exported from the library; the SDK overlay never publishes content state, so any mounted CountlyOverlayRoot stays empty.')
            .fontSize(13).fontColor(Theme.TEXT_MUTED).width('100%')
        }
      }
    }
    .width('100%').height('100%')
  }
}
