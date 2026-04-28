import { Countly, SegmentationMap } from 'countly-sdk-hos';
import { PageFrame } from '../components/PageFrame';
import { SectionCard } from '../components/SectionCard';
import { ActionButton, GhostButton } from '../components/ActionButton';
import { InputField } from '../components/InputField';
import { ButtonTone, Theme } from '../components/Theme';
import { DemoLog, SegParser, StoreKeys } from '../model/DemoState';

@Entry
@Component
struct ViewsPage {
  @State viewName: string = 'Home';
  @State viewSeg: string = 'source=demo';
  @State globalSeg: string = 'app_section=demo';
  @State extraSeg: string = 'step=2';
  @StorageLink('demo_active_view_id') activeId: string = '';
  @StorageLink('demo_active_view_name') activeName: string = '';

  private parsed(raw: string): SegmentationMap { return SegParser.parse(raw); }

  private startView = (): Promise<void> => DemoLog.safe(`startView(${this.viewName})`, async () => {
    const id: string | null = await Countly.sharedInstance().views.startView(this.viewName, this.parsed(this.viewSeg));
    this.activeId = id ?? '';
    this.activeName = this.viewName;
    DemoLog.append(`activeViewId=${this.activeId}`);
  });

  private startAutoStopped = (): Promise<void> => DemoLog.safe(`startAutoStoppedView(${this.viewName})`, async () => {
    const id: string | null = await Countly.sharedInstance().views.startAutoStoppedView(this.viewName, this.parsed(this.viewSeg));
    DemoLog.append(`auto-stopped id=${id ?? 'null'}`);
  });

  private stopById = (): Promise<void> => DemoLog.safe('stopViewWithID', async () => {
    if (this.activeId.length === 0) { DemoLog.append('no active id — start a view first'); return; }
    await Countly.sharedInstance().views.stopViewWithID(this.activeId, this.parsed(this.viewSeg));
    this.activeId = '';
    this.activeName = '';
  });

  private stopByName = (): Promise<void> => DemoLog.safe(`stopViewWithName(${this.viewName})`, async () => {
    await Countly.sharedInstance().views.stopViewWithName(this.viewName, this.parsed(this.viewSeg));
  });

  private pause = (): Promise<void> => DemoLog.safe('pauseViewWithID', () => {
    if (this.activeId.length === 0) { DemoLog.append('no active id'); return; }
    Countly.sharedInstance().views.pauseViewWithID(this.activeId);
  });

  private resume = (): Promise<void> => DemoLog.safe('resumeViewWithID', () => {
    if (this.activeId.length === 0) { DemoLog.append('no active id'); return; }
    Countly.sharedInstance().views.resumeViewWithID(this.activeId);
  });

  private stopAll = (): Promise<void> => DemoLog.safe('stopAllViews', async () => {
    await Countly.sharedInstance().views.stopAllViews(this.parsed(this.viewSeg));
    this.activeId = '';
    this.activeName = '';
  });

  private addSegById = (): Promise<void> => DemoLog.safe('addSegmentationToViewWithID', () => {
    if (this.activeId.length === 0) { DemoLog.append('no active id'); return; }
    Countly.sharedInstance().views.addSegmentationToViewWithID(this.activeId, this.parsed(this.extraSeg));
  });

  private addSegByName = (): Promise<void> => DemoLog.safe('addSegmentationToViewWithName', () => {
    Countly.sharedInstance().views.addSegmentationToViewWithName(this.viewName, this.parsed(this.extraSeg));
  });

  private setGlobal = (): Promise<void> => DemoLog.safe('setGlobalViewSegmentation', () => {
    Countly.sharedInstance().views.setGlobalViewSegmentation(this.parsed(this.globalSeg));
  });

  private updateGlobal = (): Promise<void> => DemoLog.safe('updateGlobalViewSegmentation', () => {
    Countly.sharedInstance().views.updateGlobalViewSegmentation(this.parsed(this.globalSeg));
  });

  build() {
    Column() {
      PageFrame({ title: 'Views', subtitle: 'start · stop · pause · global segmentation' }) {
      SectionCard({ title: 'Active view' }) {
        Text(`id: ${this.activeId.length > 0 ? this.activeId : '—'}`)
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
        Text(`name: ${this.activeName.length > 0 ? this.activeName : '—'}`)
          .fontSize(12).fontColor(Theme.TEXT_MUTED).width('100%')
      }

      SectionCard({ title: 'Start / stop' }) {
        InputField({ label: 'View name', value: $viewName })
        InputField({ label: 'View segmentation', value: $viewSeg, placeholder: 'source=demo' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'startView',           tone: ButtonTone.Primary, onAction: this.startView })
          ActionButton({ label: 'startAutoStopped',    tone: ButtonTone.Primary, onAction: this.startAutoStopped })
          ActionButton({ label: 'stopViewWithID',      tone: ButtonTone.Success, onAction: this.stopById })
          ActionButton({ label: 'stopViewWithName',    tone: ButtonTone.Success, onAction: this.stopByName })
          GhostButton({  label: 'pauseViewWithID',     onAction: this.pause })
          GhostButton({  label: 'resumeViewWithID',    onAction: this.resume })
          ActionButton({ label: 'stopAllViews',        tone: ButtonTone.Danger,  onAction: this.stopAll })
        }
      }

      SectionCard({ title: 'Per-view extra segmentation' }) {
        InputField({ label: 'Extra segmentation', value: $extraSeg, placeholder: 'step=2' })
        Flex({ wrap: FlexWrap.Wrap }) {
          GhostButton({ label: 'addSegmentationToViewWithID',   onAction: this.addSegById })
          GhostButton({ label: 'addSegmentationToViewWithName', onAction: this.addSegByName })
        }
      }

      SectionCard({ title: 'Global segmentation' }) {
        InputField({ label: 'Global segmentation', value: $globalSeg, placeholder: 'app_section=demo' })
        Flex({ wrap: FlexWrap.Wrap }) {
          ActionButton({ label: 'setGlobalViewSegmentation',    tone: ButtonTone.Primary, onAction: this.setGlobal })
          ActionButton({ label: 'updateGlobalViewSegmentation', tone: ButtonTone.Neutral, onAction: this.updateGlobal })
        }
      }
    }
    }
    .width('100%').height('100%')
  }
}
