import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct LocationPage {
  @State country: string = 'TR';
  @State city: string = 'Istanbul';
  @State gps: string = '41.0082,28.9784';
  @State ip: string = '1.2.3.4';

  private trim(s: string): string | null {
    const v: string = s.trim();
    return v.length === 0 ? null : v;
  }

  private set = (): Promise<void> => DemoLog.safe('setLocation', async () => {
    await Countly.sharedInstance().location.setLocation(
      this.trim(this.country),
      this.trim(this.city),
      this.trim(this.gps),
      this.trim(this.ip)
    );
  });

  private disable = (): Promise<void> => DemoLog.safe('disableLocation', async () => {
    await Countly.sharedInstance().location.disableLocation();
  });

  build() {
    Column() {
      PageFrame({ title: 'Location', subtitle: 'country · city · gps · ip' }) {
      SectionCard({ title: 'Set location', subtitle: 'Empty fields are sent as null; pass at least one.' }) {
        InputField({ label: 'Country code (ISO-2)', value: $country, placeholder: 'TR' })
        InputField({ label: 'City',                 value: $city,    placeholder: 'Istanbul' })
        InputField({ label: 'GPS (lat,lon)',        value: $gps,     placeholder: '41.0082,28.9784' })
        InputField({ label: 'IP',                   value: $ip,      placeholder: '1.2.3.4' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setLocation',     tone: ButtonTone.Primary, onAction: this.set })
          ActionButton({ label: 'disableLocation', tone: ButtonTone.Danger,  onAction: this.disable })
        }
      }

      SectionCard({ title: 'Notes' }) {
        Text('disableLocation sends an empty location payload to the server which stops all location tagging for future requests until a new setLocation call arrives.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
      }
    }
    }
    .width('100%').height('100%')
  }
}
