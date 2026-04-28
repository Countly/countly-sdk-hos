import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton } from '../components/ActionButton';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct SessionsPage {
  private begin = (): Promise<void> => DemoLog.safe('beginSession', async () => {
    await Countly.sharedInstance().sessions.beginSession();
  });

  private update = (): Promise<void> => DemoLog.safe('updateSession', async () => {
    await Countly.sharedInstance().sessions.updateSession();
  });

  private end = (): Promise<void> => DemoLog.safe('endSession', async () => {
    await Countly.sharedInstance().sessions.endSession();
  });

  private foregroundAll = (): Promise<void> => DemoLog.safe('lifecycleForegroundAll', () => {
    Countly.lifecycleForegroundAll();
  });

  private backgroundAll = (): Promise<void> => DemoLog.safe('lifecycleBackgroundAll', () => {
    Countly.lifecycleBackgroundAll();
  });

  build() {
    Column() {
      PageFrame({ title: 'Sessions', subtitle: 'manual begin / update / end' }) {
      SectionCard({ title: 'Manual session', subtitle: 'Only effective when enableManualSessionControl() was set in CountlyConfig. Current demo init does not enable it.' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'beginSession',  tone: ButtonTone.Primary, onAction: this.begin })
          ActionButton({ label: 'updateSession', tone: ButtonTone.Neutral, onAction: this.update })
          ActionButton({ label: 'endSession',    tone: ButtonTone.Danger,  onAction: this.end })
        }
      }

      SectionCard({ title: 'Lifecycle fan-out', subtitle: 'Fires foreground/background on every instance' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'foreground all', tone: ButtonTone.Success, onAction: this.foregroundAll })
          ActionButton({ label: 'background all', tone: ButtonTone.Warn,    onAction: this.backgroundAll })
        }
      }

      SectionCard({ title: 'How it works' }) {
        Text('In automatic mode (default) the SDK begins a session when the app enters the foreground and ends it on background. In manual mode you own the lifecycle — pair every beginSession with exactly one endSession, and call updateSession on your cadence to keep it alive past the session timeout.')
          .fontSize(12)
          .fontColor(Theme.TEXT_MUTED)
          .width('100%')
      }
    }
    }
    .width('100%').height('100%')
  }
}
