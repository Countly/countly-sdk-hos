import { Countly, CountlyFeature, CountlyFeatureNames } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog } from '../model/DemoState';

@Entry
@Component
struct ConsentPage {
  @State selected: string = CountlyFeature.EVENTS;
  @State featureList: string = `${CountlyFeature.EVENTS},${CountlyFeature.SESSIONS},${CountlyFeature.VIEWS}`;
  @State groupName: string = 'analytics';
  @State groupFeatures: string = `${CountlyFeature.EVENTS},${CountlyFeature.VIEWS},${CountlyFeature.SESSIONS}`;

  private splitList(raw: string): string[] {
    const out: string[] = [];
    const parts: string[] = raw.split(',');
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) out.push(p);
    }
    return out;
  }

  private grantAll = (): Promise<void> => DemoLog.safe('giveConsentAll', () => {
    Countly.sharedInstance().consent.giveConsentAll();
  });

  private revokeAll = (): Promise<void> => DemoLog.safe('removeConsentAll', () => {
    Countly.sharedInstance().consent.removeConsentAll();
  });

  private giveList = (): Promise<void> => DemoLog.safe('giveConsent(list)', () => {
    Countly.sharedInstance().consent.giveConsent(this.splitList(this.featureList));
  });

  private removeList = (): Promise<void> => DemoLog.safe('removeConsent(list)', () => {
    Countly.sharedInstance().consent.removeConsent(this.splitList(this.featureList));
  });

  private setListTrue = (): Promise<void> => DemoLog.safe('setConsent(list, true)', () => {
    Countly.sharedInstance().consent.setConsent(this.splitList(this.featureList), true);
  });

  private setListFalse = (): Promise<void> => DemoLog.safe('setConsent(list, false)', () => {
    Countly.sharedInstance().consent.setConsent(this.splitList(this.featureList), false);
  });

  private checkAll = (): Promise<void> => DemoLog.safe('checkAllConsent', () => {
    DemoLog.append(`checkAllConsent -> ${Countly.sharedInstance().consent.checkAllConsent()}`);
  });

  private checkOne = (): Promise<void> => DemoLog.safe(`getConsent(${this.selected})`, () => {
    DemoLog.append(`getConsent(${this.selected}) -> ${Countly.sharedInstance().consent.getConsent(this.selected)}`);
  });

  private createGroup = (): Promise<void> => DemoLog.safe(`createFeatureGroup(${this.groupName})`, () => {
    Countly.sharedInstance().consent.createFeatureGroup(this.groupName, this.splitList(this.groupFeatures));
  });

  private enableGroup = (): Promise<void> => DemoLog.safe(`setConsentFeatureGroup(${this.groupName}, true)`, () => {
    Countly.sharedInstance().consent.setConsentFeatureGroup(this.groupName, true);
  });

  private disableGroup = (): Promise<void> => DemoLog.safe(`setConsentFeatureGroup(${this.groupName}, false)`, () => {
    Countly.sharedInstance().consent.setConsentFeatureGroup(this.groupName, false);
  });

  @Builder featureChip(name: string) {
    Text(name)
      .fontSize(11)
      .fontColor(this.selected === name ? Theme.TEXT_INVERT : Theme.TEXT)
      .backgroundColor(this.selected === name ? Theme.PRIMARY : Theme.PRIMARY_SOFT)
      .borderRadius(999)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .margin({ right: 6, bottom: 6 })
      .onClick(() => { this.selected = name; })
  }

  build() {
    Column() {
      PageFrame({ title: 'Consent', subtitle: 'feature flags · grouping · check' }) {
      SectionCard({ title: 'Bulk' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'giveConsentAll',   tone: ButtonTone.Success, onAction: this.grantAll })
          ActionButton({ label: 'removeConsentAll', tone: ButtonTone.Danger,  onAction: this.revokeAll })
          ActionButton({ label: 'checkAllConsent',  tone: ButtonTone.Neutral, onAction: this.checkAll })
        }
      }

      SectionCard({ title: 'By feature list' }) {
        InputField({ label: 'Features (comma-separated)', value: $featureList, placeholder: 'events,sessions,views' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'giveConsent',       tone: ButtonTone.Primary, onAction: this.giveList })
          GhostButton({  label: 'removeConsent',                                 onAction: this.removeList })
          ActionButton({ label: 'setConsent(true)',  tone: ButtonTone.Primary, onAction: this.setListTrue })
          GhostButton({  label: 'setConsent(false)',                             onAction: this.setListFalse })
        }
      }

      SectionCard({ title: 'Single feature check' }) {
        Text('Selected feature')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(CountlyFeatureNames, (name: string) => {
            this.featureChip(name)
          }, (name: string) => name)
        }
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: `getConsent(${this.selected})`, tone: ButtonTone.Neutral, onAction: this.checkOne })
        }
      }

      SectionCard({ title: 'Feature groups' }) {
        InputField({ label: 'Group name',               value: $groupName })
        InputField({ label: 'Features in group',        value: $groupFeatures })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'createFeatureGroup',     tone: ButtonTone.Primary, onAction: this.createGroup })
          ActionButton({ label: 'setConsentFeatureGroup(true)',  tone: ButtonTone.Success, onAction: this.enableGroup })
          GhostButton({  label: 'setConsentFeatureGroup(false)',                              onAction: this.disableGroup })
        }
      }
    }
    }
    .width('100%').height('100%')
  }
}
