import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { Theme } from '../components/Theme';

/**
 * Feedback widgets module is disabled in this build — the page is no longer
 * registered in `main_pages.json` and the matching tile is removed from the
 * demo home, so this file should be unreachable. The placeholder content
 * stays so the file keeps compiling.
 */
@Entry
@Component
struct FeedbackPage {
  build() {
    Column() {
      PageFrame({ title: 'Feedback', subtitle: 'module disabled' }) {
        SectionCard({ title: 'Disabled' }) {
          Text('Feedback widgets are disabled in this build. The CountlyInstance.feedback facade is private and the API class is not re-exported from the library; widget overlays never render because their backing AppStorage state is never published.')
            .fontSize(13).fontColor(Theme.TEXT_MUTED).width('100%')
        }
      }
    }
    .width('100%').height('100%')
  }
}
