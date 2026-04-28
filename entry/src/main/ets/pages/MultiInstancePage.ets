import { Countly, CountlyConfig, CountlyInstance, LogLevel, SegmentationMap } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, SegParser, StoreKeys } from '../model/DemoState';

@Entry
@Component
struct MultiInstancePage {
  @StorageLink('demo_second_instance_name') instanceName: string = 'second';
  @StorageLink('demo_second_instance_created') created: boolean = false;
  @State serverUrl: string = 'https://your.server.ly';
  @State appKey: string = 'SECOND_APP_KEY';
  @State eventKey: string = 'second_demo';
  @State eventSeg: string = 'where=named-instance';

  private create = (): Promise<void> => DemoLog.safe(`createInstance(${this.instanceName})`, async () => {
    if (this.created && Countly.getInstance(this.instanceName) !== undefined) {
      DemoLog.append(`already exists — instances: ${Countly.listInstances().join(',')}`);
      return;
    }
    const cfg: CountlyConfig = new CountlyConfig(getContext(this), this.serverUrl, this.appKey)
      .setAppVersion('1.0.0');
    cfg.logging.enableLogging().setMinLevel(LogLevel.INFO);
    cfg.consent.giveAll();
    await Countly.createInstance(this.instanceName, cfg);
    this.created = true;
    DemoLog.append(`instances: ${Countly.listInstances().join(',')}`);
  });

  private list = (): Promise<void> => DemoLog.safe('listInstances', () => {
    DemoLog.append(`instances: ${Countly.listInstances().join(',') || '(none named)'}`);
  });

  private recordOn = (): Promise<void> => DemoLog.safe(`${this.instanceName}.recordEvent`, async () => {
    const inst: CountlyInstance | undefined = Countly.getInstance(this.instanceName);
    if (inst === undefined) { DemoLog.append(`no "${this.instanceName}" — create it first`); return; }
    const seg: SegmentationMap = SegParser.parse(this.eventSeg);
    await inst.events.recordEvent(this.eventKey, seg, 1, 0, 0);
  });

  private fgAll = (): Promise<void> => DemoLog.safe('lifecycleForegroundAll', () => {
    Countly.lifecycleForegroundAll();
  });

  private bgAll = (): Promise<void> => DemoLog.safe('lifecycleBackgroundAll', () => {
    Countly.lifecycleBackgroundAll();
  });

  build() {
    Column() {
      PageFrame({ title: 'Multi-instance', subtitle: 'named sub-instances with independent state' }) {
      SectionCard({ title: 'Create named instance', subtitle: 'Each instance has its own storage, device id, and queues — no shared mutable state with the default.' }) {
        InputField({ label: 'Instance name', value: $instanceName })
        InputField({ label: 'Server URL',    value: $serverUrl })
        InputField({ label: 'App key',       value: $appKey })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'createInstance', tone: ButtonTone.Primary, onAction: this.create })
          GhostButton({  label: 'listInstances',                              onAction: this.list })
        }
      }

      SectionCard({ title: 'Record on named instance' }) {
        InputField({ label: 'Event key',     value: $eventKey })
        InputField({ label: 'Segmentation', value: $eventSeg })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'recordEvent', tone: ButtonTone.Success, onAction: this.recordOn })
        }
      }

      SectionCard({ title: 'Fan-out lifecycle' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'foreground all', tone: ButtonTone.Neutral, onAction: this.fgAll })
          ActionButton({ label: 'background all', tone: ButtonTone.Neutral, onAction: this.bgAll })
        }
        Text('These dispatch to every instance (shared + named). EntryAbility already calls them on onForeground / onBackground.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }
    }
    }
    .width('100%').height('100%')
  }
}
