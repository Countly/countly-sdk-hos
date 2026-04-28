import { Countly } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, SegParser } from '../model/DemoState';

@Entry
@Component
struct UserProfilePage {
  @State name: string = 'Ada Lovelace';
  @State email: string = 'ada@example.com';
  @State phone: string = '+100000';
  @State org: string = 'Analytical Engine';
  @State customProps: string = 'tier=gold,signup_year=1843';

  @State counterKey: string = 'login_count';
  @State incrBy: string = '10';
  @State multiplyBy: string = '2';
  @State maxKey: string = 'max_level';
  @State maxValue: string = '42';
  @State minKey: string = 'min_ping';
  @State minValue: string = '12';

  @State onceKey: string = 'first_seen';
  @State onceValue: string = 'today';

  @State arrayKey: string = 'tags';
  @State arrayValue: string = 'demo';

  private n(raw: string, fallback: number): number {
    const v: number = Number(raw);
    return isNaN(v) ? fallback : v;
  }

  private setStandard = (): Promise<void> => DemoLog.safe('setProperty * 4', () => {
    const up = Countly.sharedInstance().userProfile;
    up.setProperty('name',         this.name);
    up.setProperty('email',        this.email);
    up.setProperty('phone',        this.phone);
    up.setProperty('organization', this.org);
  });

  private setCustom = (): Promise<void> => DemoLog.safe('setProperties', () => {
    Countly.sharedInstance().userProfile.setProperties(SegParser.parse(this.customProps));
  });

  private increment = (): Promise<void> => DemoLog.safe(`increment(${this.counterKey})`, () => {
    Countly.sharedInstance().userProfile.increment(this.counterKey);
  });

  private incrementByN = (): Promise<void> => DemoLog.safe(`incrementBy(${this.counterKey}, ${this.incrBy})`, () => {
    Countly.sharedInstance().userProfile.incrementBy(this.counterKey, this.n(this.incrBy, 1));
  });

  private multiplyByN = (): Promise<void> => DemoLog.safe(`multiply(${this.counterKey}, ${this.multiplyBy})`, () => {
    Countly.sharedInstance().userProfile.multiply(this.counterKey, this.n(this.multiplyBy, 1));
  });

  private saveMaxV = (): Promise<void> => DemoLog.safe(`saveMax(${this.maxKey})`, () => {
    Countly.sharedInstance().userProfile.saveMax(this.maxKey, this.n(this.maxValue, 0));
  });

  private saveMinV = (): Promise<void> => DemoLog.safe(`saveMin(${this.minKey})`, () => {
    Countly.sharedInstance().userProfile.saveMin(this.minKey, this.n(this.minValue, 0));
  });

  private setOnceV = (): Promise<void> => DemoLog.safe(`setOnce(${this.onceKey})`, () => {
    Countly.sharedInstance().userProfile.setOnce(this.onceKey, this.onceValue);
  });

  private pushV = (): Promise<void> => DemoLog.safe(`push(${this.arrayKey})`, () => {
    Countly.sharedInstance().userProfile.push(this.arrayKey, this.arrayValue);
  });

  private pushUniqueV = (): Promise<void> => DemoLog.safe(`pushUnique(${this.arrayKey})`, () => {
    Countly.sharedInstance().userProfile.pushUnique(this.arrayKey, this.arrayValue);
  });

  private pullV = (): Promise<void> => DemoLog.safe(`pull(${this.arrayKey})`, () => {
    Countly.sharedInstance().userProfile.pull(this.arrayKey, this.arrayValue);
  });

  private saveAll = (): Promise<void> => DemoLog.safe('save', async () => {
    await Countly.sharedInstance().userProfile.save();
  });

  private clearAll = (): Promise<void> => DemoLog.safe('clear', () => {
    Countly.sharedInstance().userProfile.clear();
  });

  build() {
    Column() {
      PageFrame({ title: 'User Profile', subtitle: 'props · counters · arrays · save' }) {
      SectionCard({ title: 'Standard fields' }) {
        InputField({ label: 'Name',         value: $name })
        InputField({ label: 'Email',        value: $email })
        InputField({ label: 'Phone',        value: $phone })
        InputField({ label: 'Organization', value: $org })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setProperty × 4', tone: ButtonTone.Primary, onAction: this.setStandard })
        }
      }

      SectionCard({ title: 'Custom properties' }) {
        InputField({ label: 'Properties (k=v,k2=v2)', value: $customProps })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setProperties', tone: ButtonTone.Primary, onAction: this.setCustom })
        }
      }

      SectionCard({ title: 'Counters' }) {
        InputField({ label: 'Counter key', value: $counterKey })
        Row() {
          Column() { InputField({ label: 'incrementBy', value: $incrBy, keyboardType: InputType.Number }) }.layoutWeight(1)
          Blank().width(10)
          Column() { InputField({ label: 'multiply by', value: $multiplyBy, keyboardType: InputType.Number }) }.layoutWeight(1)
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'increment',    tone: ButtonTone.Primary, onAction: this.increment })
          ActionButton({ label: 'incrementBy',  tone: ButtonTone.Primary, onAction: this.incrementByN })
          ActionButton({ label: 'multiply',     tone: ButtonTone.Primary, onAction: this.multiplyByN })
        }
      }

      SectionCard({ title: 'Max / Min' }) {
        Row() {
          Column() { InputField({ label: 'Max key',   value: $maxKey }) }.layoutWeight(1)
          Blank().width(10)
          Column() { InputField({ label: 'Max value', value: $maxValue, keyboardType: InputType.Number }) }.layoutWeight(1)
        }.width('100%')
        Row() {
          Column() { InputField({ label: 'Min key',   value: $minKey }) }.layoutWeight(1)
          Blank().width(10)
          Column() { InputField({ label: 'Min value', value: $minValue, keyboardType: InputType.Number }) }.layoutWeight(1)
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'saveMax', tone: ButtonTone.Neutral, onAction: this.saveMaxV })
          ActionButton({ label: 'saveMin', tone: ButtonTone.Neutral, onAction: this.saveMinV })
        }
      }

      SectionCard({ title: 'Set once' }) {
        InputField({ label: 'Key',   value: $onceKey })
        InputField({ label: 'Value', value: $onceValue })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setOnce', tone: ButtonTone.Neutral, onAction: this.setOnceV })
        }
      }

      SectionCard({ title: 'Array operations' }) {
        InputField({ label: 'Array key',   value: $arrayKey })
        InputField({ label: 'Array value', value: $arrayValue })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'push',       tone: ButtonTone.Primary, onAction: this.pushV })
          ActionButton({ label: 'pushUnique', tone: ButtonTone.Primary, onAction: this.pushUniqueV })
          GhostButton({  label: 'pull',                                   onAction: this.pullV })
        }
      }

      SectionCard({ title: 'Persistence' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'save',  tone: ButtonTone.Success, onAction: this.saveAll })
          ActionButton({ label: 'clear', tone: ButtonTone.Danger,  onAction: this.clearAll })
        }
        Text('save() commits all pending mutations to the server. clear() drops pending local mutations without sending.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }
    }
    }
    .width('100%').height('100%')
  }
}
