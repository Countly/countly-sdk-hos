import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, StoreKeys } from '../model/DemoState';

@Entry
@Component
struct ShutdownPage {
  @State confirmed: boolean = false;

  private halt = (): Promise<void> => DemoLog.safe('haltAll', async () => {
    await Countly.haltAll();
    this.confirmed = false;
    // Mirror SDK state back into AppStorage: the Index header flips to
    // "not initialized" and MultiInstancePage forgets the named instance
    // so its guard shows "create it first" instead of "already exists".
    AppStorage.SetOrCreate<boolean>(StoreKeys.SDK_READY, false);
    AppStorage.SetOrCreate<boolean>(StoreKeys.SECOND_INSTANCE_CREATED, false);
  });

  build() {
    Column() {
      PageFrame({ title: 'Shutdown', subtitle: 'halt every instance' }) {
      SectionCard({ title: 'Danger zone', subtitle: 'haltAll stops the request queue, cancels timers, flushes open sessions/events, and forgets every named instance. After this point sharedInstance() throws until EntryAbility re-initializes.' }) {
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.confirmed })
            .onChange((v: boolean): void => { this.confirmed = v; })
          Text('I understand this is destructive')
            .fontSize(12).fontColor(Theme.TEXT).margin({ left: 10 })
        }
        .width('100%')
        .margin({ bottom: 10 })

        Flex({ wrap: FlexWrap.Wrap }) {
          if (this.confirmed) {
            ActionButton({ label: 'haltAll', tone: ButtonTone.Danger, onAction: this.halt })
          } else {
            GhostButton({ label: 'haltAll (locked)', onAction: (): void => { DemoLog.append('flip the switch to enable'); } })
          }
        }
      }
    }
    }
    .width('100%').height('100%')
  }
}
