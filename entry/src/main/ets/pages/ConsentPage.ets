import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton } from '../components/ActionButton';
import { ButtonTone } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct ConsentPage {
  private grantAll = (): Promise<void> => DemoLog.safe('giveConsentAll', () => {
    Countly.sharedInstance().consent.giveConsentAll();
  });

  private revokeAll = (): Promise<void> => DemoLog.safe('removeConsentAll', () => {
    Countly.sharedInstance().consent.removeConsentAll();
  });

  private checkAll = (): Promise<void> => DemoLog.safe('checkAllConsent', () => {
    DemoLog.append(`checkAllConsent -> ${Countly.sharedInstance().consent.checkAllConsent()}`);
  });

  build() {
    Column() {
      PageFrame({ title: 'Consent', subtitle: 'bulk grant/revoke · check' }) {
        SectionCard({ title: 'Bulk' }) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ActionButton({ label: 'giveConsentAll',   tone: ButtonTone.Success, onAction: this.grantAll })
            ActionButton({ label: 'removeConsentAll', tone: ButtonTone.Danger,  onAction: this.revokeAll })
            ActionButton({ label: 'checkAllConsent',  tone: ButtonTone.Neutral, onAction: this.checkAll })
          }
        }
      }
    }
    .width('100%').height('100%')
  }
}
