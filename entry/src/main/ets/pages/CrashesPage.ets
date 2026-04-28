import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, SegParser } from '../model/DemoState';

@Entry
@Component
struct CrashesPage {
  @State breadcrumb: string = 'user tapped button';
  @State errMsg: string = 'Simulated handled exception';
  @State customSeg: string = 'context=demo';

  private addBreadcrumb = (): Promise<void> => DemoLog.safe('addCrashBreadcrumb', () => {
    Countly.sharedInstance().crashes.addCrashBreadcrumb(`${this.breadcrumb} @ ${Date.now()}`);
  });

  private recordHandled = (): Promise<void> => DemoLog.safe('recordHandledException', async () => {
    try {
      throw new Error(this.errMsg);
    } catch (e) {
      await Countly.sharedInstance().crashes.recordHandledException(e as Error, SegParser.parse(this.customSeg));
    }
  });

  private recordUnhandled = (): Promise<void> => DemoLog.safe('recordUnhandledException', async () => {
    try {
      throw new Error(this.errMsg);
    } catch (e) {
      await Countly.sharedInstance().crashes.recordUnhandledException(e as Error, SegParser.parse(this.customSeg));
    }
  });

  build() {
    Column() {
      PageFrame({ title: 'Crashes', subtitle: 'breadcrumbs · handled · unhandled' }) {
      SectionCard({ title: 'Breadcrumb' }) {
        InputField({ label: 'Breadcrumb text', value: $breadcrumb })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'addCrashBreadcrumb', tone: ButtonTone.Primary, onAction: this.addBreadcrumb })
        }
      }

      SectionCard({ title: 'Exception recording' }) {
        InputField({ label: 'Error message',    value: $errMsg })
        InputField({ label: 'Custom segmentation', value: $customSeg, placeholder: 'context=demo' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'recordHandledException',   tone: ButtonTone.Warn,   onAction: this.recordHandled })
          ActionButton({ label: 'recordUnhandledException', tone: ButtonTone.Danger, onAction: this.recordUnhandled })
        }
      }

      SectionCard({ title: 'Notes' }) {
        Text('Both methods capture the stack trace from the supplied Error. Breadcrumbs added before a crash are included in the report (bounded ring buffer; set via config).')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
      }
    }
    }
    .width('100%').height('100%')
  }
}
