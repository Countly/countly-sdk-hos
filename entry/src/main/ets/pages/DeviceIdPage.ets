import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct DeviceIdPage {
  @State newId: string = 'demo-user-1';

  private setID = (): Promise<void> => DemoLog.safe(`setID(${this.newId})`, async () => {
    await Countly.sharedInstance().deviceId.setID(this.newId);
  });

  private changeMerge = (): Promise<void> => DemoLog.safe(`changeWithMerge(${this.newId})`, async () => {
    await Countly.sharedInstance().deviceId.changeWithMerge(this.newId);
  });

  private changeNoMerge = (): Promise<void> => DemoLog.safe(`changeWithoutMerge(${this.newId})`, async () => {
    await Countly.sharedInstance().deviceId.changeWithoutMerge(this.newId);
  });

  private enableOffline = (): Promise<void> => DemoLog.safe('enableOfflineMode', async () => {
    await Countly.sharedInstance().deviceId.enableOfflineMode();
  });

  private disableOffline = (): Promise<void> => DemoLog.safe('disableOfflineMode', async () => {
    await Countly.sharedInstance().deviceId.disableOfflineMode();
  });

  private show = (): Promise<void> => DemoLog.safe('getID / getType', () => {
    const id = Countly.sharedInstance().deviceId;
    DemoLog.append(`id=${id.getID()} type=${id.getType()}`);
  });

  build() {
    Column() {
      PageFrame({ title: 'Device ID', subtitle: 'set · change (merge/no-merge) · offline' }) {
      SectionCard({ title: 'Current identity' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'show current id', tone: ButtonTone.Neutral, onAction: this.show })
        }
        Text('Output is printed to the log panel. The full device id is redacted from SDK logs on init — the type is always safe to show.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }

      SectionCard({ title: 'Change device id' }) {
        InputField({ label: 'New device id', value: $newId })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setID',              tone: ButtonTone.Primary, onAction: this.setID })
          ActionButton({ label: 'changeWithMerge',    tone: ButtonTone.Success, onAction: this.changeMerge })
          ActionButton({ label: 'changeWithoutMerge', tone: ButtonTone.Danger,  onAction: this.changeNoMerge })
        }
        Text('• setID: first-time assignment (idempotent).\n• changeWithMerge: merge server-side data under new id, keep local state.\n• changeWithoutMerge: treat as a different user — clears consent, timed events, and RC cache.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }

      SectionCard({ title: 'Offline mode' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'enableOfflineMode', tone: ButtonTone.Warn, onAction: this.enableOffline })
          ActionButton({ label: 'disableOfflineMode', tone: ButtonTone.Neutral, onAction: this.disableOffline })
        }
        Text('Records under a placeholder id and queues everything until a real id is set via setID/changeWith* or disableOfflineMode. Useful after logout.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }
    }
    }
    .width('100%').height('100%')
  }
}
