import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct MetricsPage {
  @State overrides: string = '_app_version=1.0.0-demo';

  private parse(): Record<string, string> {
    const out: Record<string, string> = {};
    if (this.overrides.trim().length === 0) return out;
    const pairs: string[] = this.overrides.split(',');
    for (let i = 0; i < pairs.length; i++) {
      const p: string = pairs[i].trim();
      if (p.length === 0) continue;
      const eq: number = p.indexOf('=');
      if (eq === -1) continue;
      const k: string = p.substring(0, eq).trim();
      const v: string = p.substring(eq + 1).trim();
      if (k.length > 0) out[k] = v;
    }
    return out;
  }

  private record = (): Promise<void> => DemoLog.safe('recordMetrics', async () => {
    await Countly.sharedInstance().requests.recordMetrics(this.parse());
  });

  build() {
    Column() {
      PageFrame({ title: 'Metrics', subtitle: 'override platform metrics' }) {
      SectionCard({ title: 'Metric override', subtitle: 'Overrides specific metric fields on the next request. Accepts standard Countly keys (_app_version, _os, _device, etc.).' }) {
        InputField({ label: 'Overrides (k=v,k2=v2)', value: $overrides, placeholder: '_app_version=1.0.0-demo' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'recordMetrics', tone: ButtonTone.Primary, onAction: this.record })
        }
      }

      SectionCard({ title: 'Notes' }) {
        Text('This enqueues a single /i request carrying a metrics blob built from DeviceInfo.collect() plus your overrides. Values sent here win over anything collected automatically.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
      }
    }
    }
    .width('100%').height('100%')
  }
}
