import { Countly, SegmentationMap } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { Theme, ButtonTone } from '../components/Theme';
import { DemoLog, SegParser } from '../model/DemoState';

@Entry
@Component
struct EventsPage {
  // Renamed from `key`: ArkUI's CustomComponent base class reserves `key`
  // for the built-in id-assigning builder, so `@State key: string` fails
  // the type check.
  @State eventKey: string = 'purchase';
  @State segmentation: string = 'item=book,price=9.99';
  @State count: string = '1';
  @State sum: string = '9.99';
  @State dur: string = '0';
  @State timedKey: string = 'timed_flow';

  private n(raw: string, fallback: number): number {
    const v: number = Number(raw);
    return isNaN(v) ? fallback : v;
  }

  private parsedSeg(): SegmentationMap {
    return SegParser.parse(this.segmentation);
  }

  private record = (): Promise<void> => DemoLog.safe(`recordEvent(${this.eventKey})`, async () => {
    await Countly.sharedInstance().events.recordEvent(
      this.eventKey,
      this.parsedSeg(),
      this.n(this.count, 1),
      this.n(this.sum, 0),
      this.n(this.dur, 0)
    );
  });

  private startTimed = (): Promise<void> => DemoLog.safe(`startEvent(${this.timedKey})`, () => {
    Countly.sharedInstance().events.startEvent(this.timedKey);
  });

  private endTimed = (): Promise<void> => DemoLog.safe(`endEvent(${this.timedKey})`, async () => {
    await Countly.sharedInstance().events.endEvent(
      this.timedKey,
      this.parsedSeg(),
      this.n(this.count, 1),
      this.n(this.sum, 0)
    );
  });

  private cancelTimed = (): Promise<void> => DemoLog.safe(`cancelEvent(${this.timedKey})`, () => {
    Countly.sharedInstance().events.cancelEvent(this.timedKey);
  });

  build() {
    Column() {
      PageFrame({ title: 'Events', subtitle: 'recordEvent · timed events · segmentation' }) {
      SectionCard({ title: 'Record event' }) {
        InputField({ label: 'Key', value: $eventKey, placeholder: 'purchase' })
        InputField({ label: 'Segmentation (k=v,k2=v2)', value: $segmentation, placeholder: 'item=book,price=9.99' })
        Row() {
          Column() { InputField({ label: 'Count', value: $count, keyboardType: InputType.Number }) }.layoutWeight(1)
          Blank().width(10)
          Column() { InputField({ label: 'Sum', value: $sum, keyboardType: InputType.Number }) }.layoutWeight(1)
          Blank().width(10)
          Column() { InputField({ label: 'Dur (ms)', value: $dur, keyboardType: InputType.Number }) }.layoutWeight(1)
        }.width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'recordEvent', tone: ButtonTone.Primary, onAction: this.record })
        }
      }

      SectionCard({ title: 'Timed event', subtitle: 'start → end measures duration automatically' }) {
        InputField({ label: 'Timed key', value: $timedKey, placeholder: 'timed_flow' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'startEvent', tone: ButtonTone.Primary, onAction: this.startTimed })
          ActionButton({ label: 'endEvent',   tone: ButtonTone.Success, onAction: this.endTimed })
          GhostButton({ label: 'cancelEvent', onAction: this.cancelTimed })
        }
      }
    }
    }
    .width('100%').height('100%')
  }
}
