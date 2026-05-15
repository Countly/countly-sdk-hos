import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton } from '../components/ActionButton';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct ConfigurationPage {
  // Mirror of the live ServerConfig fields. Refreshed via the snapshot
  // button so the display reflects whatever a server fetch / dev-supplied
  // bootstrap most recently applied.
  @State trackingEnabled: boolean = true;
  @State networkingEnabled: boolean = true;
  @State sessionTrackingEnabled: boolean = true;
  @State viewTrackingEnabled: boolean = true;
  @State crashReportingEnabled: boolean = true;
  @State customEventTrackingEnabled: boolean = true;
  @State eventQueueSize: number = 100;
  @State requestQueueSize: number = 1000;
  @State sessionUpdateInterval: number = 60;
  @State limitKeyLength: number = 128;
  @State automaticViewTrackingEnabled: boolean = false;
  @State automaticSessionTrackingEnabled: boolean = true;
  @State automaticCrashReportingEnabled: boolean = false;
  @State journeyTriggerEvents: string = '';
  @State journeyTriggerViews: string = '';

  private snapshot = (): Promise<void> => DemoLog.safe('snapshot SBS', async () => {
    const sc = Countly.sharedInstance().config.serverConfig;
    this.trackingEnabled = sc.trackingEnabled;
    this.networkingEnabled = sc.networkingEnabled;
    this.sessionTrackingEnabled = sc.sessionTrackingEnabled;
    this.viewTrackingEnabled = sc.viewTrackingEnabled;
    this.crashReportingEnabled = sc.crashReportingEnabled;
    this.customEventTrackingEnabled = sc.customEventTrackingEnabled;
    this.eventQueueSize = sc.eventQueueSize;
    this.requestQueueSize = sc.requestQueueSize;
    this.sessionUpdateInterval = sc.sessionUpdateInterval;
    this.limitKeyLength = sc.limitKeyLength;
    this.automaticViewTrackingEnabled = sc.automaticViewTrackingEnabled;
    this.automaticSessionTrackingEnabled = sc.automaticSessionTrackingEnabled;
    this.automaticCrashReportingEnabled = sc.automaticCrashReportingEnabled;
    this.journeyTriggerEvents = sc.journeyTriggerEvents.join(', ');
    this.journeyTriggerViews = sc.journeyTriggerViews.join(', ');
  });

  build() {
    Column() {
      PageFrame({ title: 'SDK Behavior', subtitle: 'server-driven runtime config' }) {
        SectionCard({ title: 'Live ServerConfig (read-only)', subtitle: 'Tap snapshot to refresh — values reflect the most recent /o/sdk?method=sc apply or dev-supplied bootstrap.' }) {
          ActionButton({ label: 'snapshot', tone: ButtonTone.Primary, onAction: this.snapshot })
          this.row('tracking',           String(this.trackingEnabled))
          this.row('networking',         String(this.networkingEnabled))
          this.row('sessionTracking',    String(this.sessionTrackingEnabled))
          this.row('viewTracking',       String(this.viewTrackingEnabled))
          this.row('crashReporting',     String(this.crashReportingEnabled))
          this.row('customEventTracking',String(this.customEventTrackingEnabled))
          this.row('eventQueueSize',     String(this.eventQueueSize))
          this.row('requestQueueSize',   String(this.requestQueueSize))
          this.row('sessionUpdateInt',   `${this.sessionUpdateInterval}s`)
          this.row('limitKeyLength',     `${this.limitKeyLength} chars`)
          this.row('autoViewTracking',   String(this.automaticViewTrackingEnabled))
          this.row('autoSessionTracking',String(this.automaticSessionTrackingEnabled))
          this.row('autoCrashReporting', String(this.automaticCrashReportingEnabled))
          this.row('journeyTriggers',    this.journeyTriggerEvents.length > 0 ? this.journeyTriggerEvents : '(none)')
          this.row('journeyTriggerViews',this.journeyTriggerViews.length > 0 ? this.journeyTriggerViews : '(none)')
        }

        SectionCard({ title: 'Notes' }) {
          Text('Pre-init configuration lives on CountlyConfig — call setSDKBehaviorSettings(jsonString) to ship a bootstrap, or disableSDKBehaviorSettingsUpdates() to pin the SDK to dev-supplied + stored only. The fetch fires once on init and refreshes every 4h by default; the response is persisted to cly_sbs and survives restarts.')
            .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
        }
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  private row(name: string, value: string) {
    Row() {
      Text(name).fontSize(12).fontColor(Theme.TEXT_MUTED).layoutWeight(1)
      Text(value).fontSize(12).fontColor(Theme.TEXT_PRIMARY)
    }.width('100%').padding({ top: 4, bottom: 4 })
  }
}
