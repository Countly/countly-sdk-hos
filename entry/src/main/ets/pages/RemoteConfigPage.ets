import { Countly, RCData, RCDownloadCallback, RequestResult } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, DemoState } from '../model/DemoState';

class DemoDownloadCallback {
  public static cb: RCDownloadCallback = (
    result: RequestResult,
    error: string | null,
    fullValueUpdate: boolean,
    downloaded: Record<string, RCData>
  ): void => {
    const n: number = Object.keys(downloaded).length;
    DemoLog.append(`rc callback: result=${result} err=${error ?? 'none'} full=${fullValueUpdate} keys=${n}`);
  };
}

@Entry
@Component
struct RemoteConfigPage {
  @State keysInput: string = 'key1,key2';
  @State singleKey: string = 'key1';

  private splitKeys(): string[] {
    const out: string[] = [];
    const parts: string[] = this.keysInput.split(',');
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i].trim();
      if (p.length > 0) out.push(p);
    }
    return out;
  }

  private fetchAll = (): Promise<void> => DemoLog.safe('downloadAllKeys', async () => {
    await Countly.sharedInstance().remoteConfig.downloadAllKeys(DemoDownloadCallback.cb);
  });

  private fetchSpecific = (): Promise<void> => DemoLog.safe('downloadSpecificKeys', async () => {
    await Countly.sharedInstance().remoteConfig.downloadSpecificKeys(this.splitKeys(), DemoDownloadCallback.cb);
  });

  private fetchOmitting = (): Promise<void> => DemoLog.safe('downloadOmittingKeys', async () => {
    await Countly.sharedInstance().remoteConfig.downloadOmittingKeys(this.splitKeys(), DemoDownloadCallback.cb);
  });

  private getOne = (): Promise<void> => DemoLog.safe(`getValue(${this.singleKey})`, () => {
    const v: RCData | null = Countly.sharedInstance().remoteConfig.getValue(this.singleKey);
    DemoLog.append(`  → value=${v === null ? 'null' : JSON.stringify(v.value)} current=${v?.isCurrentUsersData ?? false}`);
  });

  private dump = (): Promise<void> => DemoLog.safe('getValues', () => {
    const all: Record<string, RCData> = Countly.sharedInstance().remoteConfig.getValues();
    DemoState.lastRcValues = all;
    const keys: string[] = Object.keys(all);
    DemoLog.append(`  → ${keys.length} keys: ${keys.join(',')}`);
  });

  private clearAll = (): Promise<void> => DemoLog.safe('clearAllRemoteConfig', async () => {
    await Countly.sharedInstance().remoteConfig.clearAllRemoteConfig();
  });

  private registerCb = (): Promise<void> => DemoLog.safe('registerDownloadCallback', () => {
    Countly.sharedInstance().remoteConfig.registerDownloadCallback(DemoDownloadCallback.cb);
  });

  private removeCb = (): Promise<void> => DemoLog.safe('removeDownloadCallback', () => {
    Countly.sharedInstance().remoteConfig.removeDownloadCallback(DemoDownloadCallback.cb);
  });

  build() {
    Column() {
      PageFrame({ title: 'Remote Config', subtitle: 'download · read · callbacks' }) {
      SectionCard({ title: 'Download' }) {
        InputField({ label: 'Keys (comma-separated) for specific / omitting', value: $keysInput, placeholder: 'key1,key2' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'downloadAllKeys',      tone: ButtonTone.Primary, onAction: this.fetchAll })
          ActionButton({ label: 'downloadSpecificKeys', tone: ButtonTone.Primary, onAction: this.fetchSpecific })
          ActionButton({ label: 'downloadOmittingKeys', tone: ButtonTone.Primary, onAction: this.fetchOmitting })
          ActionButton({ label: 'clearAllRemoteConfig', tone: ButtonTone.Danger,  onAction: this.clearAll })
        }
      }

      SectionCard({ title: 'Read cached values' }) {
        InputField({ label: 'Key', value: $singleKey })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'getValue',  tone: ButtonTone.Neutral, onAction: this.getOne })
          ActionButton({ label: 'getValues (dump all)', tone: ButtonTone.Neutral, onAction: this.dump })
        }
      }

      SectionCard({ title: 'Global callback' }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'registerDownloadCallback', tone: ButtonTone.Success, onAction: this.registerCb })
          GhostButton({  label: 'removeDownloadCallback',                              onAction: this.removeCb })
        }
        Text('Registered callback fires on every download regardless of which download method triggered it.')
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%').margin({ top: 6 })
      }
    }
    }
    .width('100%').height('100%')
  }
}
