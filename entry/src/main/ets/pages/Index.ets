import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import { Countly } from 'countly-sdk-hos';
import { Theme } from '../components/Theme';
import { LogPanel } from '../components/LogPanel';
import { DemoLog, StoreKeys } from '../model/DemoState';

// Bundle name comes from `AppScope/app.json5`. Hard-coded here because
// HMOS does not expose a typed accessor on `common.Context` for it the way
// Android exposes `Context.getPackageName()` — keep this in sync if the
// bundleName ever changes.
const DEMO_BUNDLE_NAME: string = 'ly.count.sdk.hos.demo';

class FeatureTile {
  public title: string;
  public subtitle: string;
  public badge: string;
  public accent: string;
  public route: string;

  constructor(title: string, subtitle: string, badge: string, accent: string, route: string) {
    this.title = title;
    this.subtitle = subtitle;
    this.badge = badge;
    this.accent = accent;
    this.route = route;
  }
}

const TILES: FeatureTile[] = [
  new FeatureTile('Events',         'record / timed / segmented',    'EV', '#2563EB', 'pages/EventsPage'),
  new FeatureTile('Sessions',       'manual begin / update / end',   'SE', '#7C3AED', 'pages/SessionsPage'),
  new FeatureTile('Views',          'start, stop, pause, global',    'VW', '#0EA5E9', 'pages/ViewsPage'),
  new FeatureTile('Crashes',        'breadcrumb + handled/unhandled','CR', '#EF4444', 'pages/CrashesPage'),
  new FeatureTile('User Profile',   'props, counters, arrays',       'UP', '#F59E0B', 'pages/UserProfilePage'),
  new FeatureTile('Consent',        'features + groups',             'CN', '#10B981', 'pages/ConsentPage'),
  new FeatureTile('Device ID',      'set / change / temp',           'ID', '#14B8A6', 'pages/DeviceIdPage'),
  new FeatureTile('Location',       'country / city / gps / ip',     'LC', '#3B82F6', 'pages/LocationPage'),
  new FeatureTile('Metrics',        'override fields',               'MT', '#8B5CF6', 'pages/MetricsPage'),
  new FeatureTile('Remote Config',  'download + read values',        'RC', '#06B6D4', 'pages/RemoteConfigPage'),
  // Push, Content Zone, and Feedback tiles are removed while their modules
  // are disabled. The page files stay on disk (as inert placeholders) for a
  // clean re-enable path.
  new FeatureTile('SDK Behavior',   'server-driven config',          'SC', '#22C55E', 'pages/ConfigurationPage'),
  new FeatureTile('Multi-instance', 'named sub-instances',           'MI', '#0F766E', 'pages/MultiInstancePage'),
  new FeatureTile('Shutdown',       'halt everything',               'HL', '#64748B', 'pages/ShutdownPage')
];

@Entry
@Component
struct Index {
  // Reactive readiness flag published by EntryAbility after initShared
  // resolves (and reset by ShutdownPage on haltAll). Required because
  // onWindowStageCreate does not await the async onCreate, so this page
  // may render before the SDK is usable.
  @StorageLink('demo_sdk_ready') sdkReady: boolean = false;

  private navigate(route: string, title: string): void {
    router.pushUrl({ url: route }).catch((err: Object): void => {
      DemoLog.append(`nav ${title} ERR: ${err}`);
    });
  }

  /**
   * Launch a sibling UIAbility to exercise the SDK's automatic view
   * tracking path. Auto-view fires on `abilityLifecycle.onAbilityForeground`
   * which the platform emits ONLY on cross-ability transitions (not on
   * `router.pushUrl` between pages of the same ability), so this is the
   * only demo control that produces `[CLY]_view` events with non-Entry
   * names. The bundle name is the demo HAP's bundleName from
   * `AppScope/app.json5`.
   */
  private launchAbility(abilityName: string): void {
    const ctx: common.UIAbilityContext | undefined =
      this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!ctx) {
      DemoLog.append(`launch ${abilityName} ERR: no UIAbilityContext`);
      return;
    }
    const want: Want = { bundleName: DEMO_BUNDLE_NAME, abilityName: abilityName };
    ctx.startAbility(want).then((): void => {
      DemoLog.append(`startAbility(${abilityName}) OK`);
    }).catch((err: Object): void => {
      DemoLog.append(`startAbility(${abilityName}) ERR: ${err}`);
    });
  }

  private statusLine(): string {
    if (!this.sdkReady) {
      return 'initializing — if this stays, check COUNTLY_SERVER_URL / COUNTLY_APP_KEY in EntryAbility.ets';
    }
    try {
      return `device id type: ${Countly.sharedInstance().deviceId.getType()}`;
    } catch (e) {
      return 'sdk not initialized';
    }
  }

  @Builder
  tile(t: FeatureTile) {
    Column() {
      Text(t.badge)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT_INVERT)
        .width(36)
        .height(36)
        .textAlign(TextAlign.Center)
        .backgroundColor(t.accent)
        .borderRadius(8)
        .margin({ bottom: 10 })

      Text(t.title)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.TEXT)
        .width('100%')
        .textAlign(TextAlign.Start)

      Text(t.subtitle)
        .fontSize(11)
        .fontColor(Theme.TEXT_MUTED)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .backgroundColor(Theme.CARD)
    .borderRadius(Theme.RADIUS_LG)
    .border({ width: 1, color: Theme.BORDER })
    .onClick(() => { this.navigate(t.route, t.title); })
  }

  build() {
    Column() {
      Column() {
        Text('Countly SDK')
          .fontSize(13)
          .fontColor('#94A3B8')
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .textAlign(TextAlign.Start)
        Text('HarmonyOS Demo')
          .fontSize(24)
          .fontColor(Theme.TEXT_INVERT)
          .fontWeight(FontWeight.Bold)
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 2 })
        Text(this.statusLine())
          .fontSize(11)
          .fontColor('#94A3B8')
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ top: 10 })

        // Auto-view tracking demo: launch a sibling UIAbility so the SDK's
        // `abilityLifecycle.onAbilityForeground` subscription fires and emits
        // a `[CLY]_view` event. Required because intra-ability `router.pushUrl`
        // does NOT trigger that lifecycle hook (see memory
        // `project_auto_lifecycle.md`).
        Row() {
          Button('Launch Secondary')
            .fontSize(12)
            .fontColor(Theme.TEXT_INVERT)
            .backgroundColor('#2563EB')
            .type(ButtonType.Normal)
            .borderRadius(Theme.RADIUS_MD)
            .height(36)
            .layoutWeight(1)
            .margin({ right: 6 })
            .onClick(() => { this.launchAbility('SecondaryAbility'); })
          Button('Launch Tertiary')
            .fontSize(12)
            .fontColor(Theme.TEXT_INVERT)
            .backgroundColor('#7C3AED')
            .type(ButtonType.Normal)
            .borderRadius(Theme.RADIUS_MD)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 6 })
            .onClick(() => { this.launchAbility('TertiaryAbility'); })
        }
        .width('100%')
        .margin({ top: 12 })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 22, bottom: 20 })
      .backgroundColor(Theme.HEADER)
      .alignItems(HorizontalAlign.Start)

      Scroll() {
        Grid() {
          ForEach(TILES, (t: FeatureTile) => {
            GridItem() {
              this.tile(t)
            }
          }, (t: FeatureTile) => t.route)
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(10)
        .rowsGap(10)
        .padding(14)
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .backgroundColor(Theme.BG)

      LogPanel()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.BG)
  }
}
