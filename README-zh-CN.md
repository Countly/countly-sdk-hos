![API](https://img.shields.io/badge/API-12%2B-brightgreen.svg?style=flat)
![Status](https://img.shields.io/badge/status-experimental-orange.svg?style=flat)

[English](./README.md) · **简体中文**

# Countly HarmonyOS SDK

本仓库包含 **实验性** 的 Countly HarmonyOS SDK，可集成到使用 ArkTS 编写的 HarmonyOS NEXT Stage 模型应用中。Countly HarmonyOS SDK 适用于 [Countly Lite](https://countly.com/lite)、[Countly Flex](https://countly.com/flex) 与 [Countly Enterprise](https://countly.com/enterprise)。

> **实验性版本。** SDK 正在持续开发中，公开 API 遵循 Countly 跨平台 SDK 的统一约定。

## Countly 是什么？

[Countly](https://countly.com) 是面向 [移动端](https://countly.com/mobile-analytics)、[Web 端](https://countly.com/web-analytics) 与 [桌面端](https://countly.com/desktop-analytics) 应用的产品分析与创新使能平台,帮助团队追踪产品表现、用户旅程与行为。Countly [秉持隐私优先的设计理念](https://countly.com/privacy-by-design),让您在保护用户隐私的前提下持续优化产品、提供个性化体验,并达成关键业务与营收目标。

追踪、度量、行动 — 在 Countly 中一站完成。

* **有问题或需求?** [加入 Countly 社区 Discord](https://discord.gg/countly)
* **寻找 Countly 服务端?** [Countly 服务端仓库](https://github.com/Countly/countly-server)
* **寻找其他 Countly SDK?** [所有移动、Web 与桌面 SDK 总览](https://support.count.ly/hc/en-us/articles/360037236571-Downloading-and-Installing-SDKs#h_01H9QCP8G5Y9PZJGERZ4XWYDY9)

## 集成 Countly SDK

完整文档请见 [SDK 使用指南](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS)。

将 SDK 添加到工程的步骤请见 [文档对应章节](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS#h_01HND_ADDSDK)。

最简集成示例请见 [文档的 Minimal Setup 章节](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS#h_01HND_MINIMAL)。

完整集成示例参见 [demo 工程](https://github.com/Countly/countly-sdk-hos/tree/staging/entry/src/main/ets)。

本 SDK 支持以下功能:
* [事件分析(Analytics)](https://support.count.ly/hc/en-us/articles/4431589003545-Analytics)
* [用户画像(User Profiles)](https://support.count.ly/hc/en-us/articles/4403281285913-User-Profiles)
* [崩溃报告(Crash Reports)](https://support.count.ly/hc/en-us/articles/4404213566105-Crashes-Errors)
* [A/B 测试](https://support.count.ly/hc/en-us/articles/4416496362393-A-B-Testing-)

## 安装

在模块级 `oh-package.json5` 的 `dependencies:` 中添加:

```json
{
  "dependencies": {
    "countly-sdk-hos": "^26.1.0"
  }
}
```

### 支持的平台

* **HarmonyOS NEXT 5.0 及以上**(API level **12+**)
* ArkTS 严格模式(SDK 在严格规则集下构建与测试)
* 仅支持 Stage Model UIAbility(不支持 FA Model)

### 必需权限

SDK 需要网络访问权限。请在 `module.json5` 中确保如下权限已声明:

```json
{
  "module": {
    "requestPermissions": [
      { "name": "ohos.permission.INTERNET" },
      { "name": "ohos.permission.GET_NETWORK_INFO" }
    ]
  }
}
```

## 使用方式

### 初始化

**推荐方式:** 在 `AbilityStage` 中初始化 SDK。`AbilityStage.onCreate` 在每个 HAP 模块进程中只会执行一次,**且早于任何 UIAbility 创建**,因此 SDK 的 `applicationStateChange` 与 `abilityLifecycle` 订阅会在平台首次前台切换之前完成注册 — 不会丢失冷启动的会话与首次视图。

创建 `entry/src/main/ets/myabilitystage/MyAbilityStage.ets`:

```typescript
import AbilityStage from '@ohos.app.ability.AbilityStage';
import { Countly, CountlyConfig } from 'countly-sdk-hos';

export default class MyAbilityStage extends AbilityStage {
  onCreate(): void {
    const config = new CountlyConfig(
      this.context,          // common.Context(此处为 AbilityStageContext)
      'https://YOUR_SERVER', // Countly 服务器地址
      'YOUR_APP_KEY'         // 控制台中的 App Key
    );
    // onCreate 是同步 void 方法 — 异步 init 采用 fire-and-forget。
    Countly.initShared(config).catch((err) => console.error(`Countly init failed: ${err}`));
  }
}
```

在 `entry/src/main/module.json5` 模块级配置中接入 AbilityStage:

```json
{
  "module": {
    "srcEntry": "./ets/myabilitystage/MyAbilityStage.ets"
  }
}
```

如此一来,`EntryAbility` 不再承担任何 SDK 代码 — 无需 `Countly.initShared` 调用,也不需要重写 `onForeground` / `onBackground`。

**备选 — UIAbility 初始化。** 如不愿引入 `AbilityStage`,也可在 `EntryAbility.onCreate` 中初始化。SDK 仍可正常运行,但平台的冷启动前台切换可能在异步 `init()` 链(存储 + 设备 ID + 模块初始化)完成之前先行触发 — 这种竞态可能导致冷启动的首次会话与首个自动视图丢失。后续前后台切换不受影响。多窗口或生产级集成请优先使用 `AbilityStage`。

```typescript
import UIAbility from '@ohos.app.ability.UIAbility';
import { Countly, CountlyConfig } from 'countly-sdk-hos';

export default class EntryAbility extends UIAbility {
  async onCreate(want, launchParam): Promise<void> {
    const config = new CountlyConfig(this.context, 'https://YOUR_SERVER', 'YOUR_APP_KEY');
    await Countly.initShared(config);
    // 生命周期由 SDK 自动接入 — 无需重写 onForeground / onBackground。
  }
}
```

> **关于 AbilityStageContext 的说明。** 从 `AbilityStage` 传入 `CountlyConfig` 的 context 类型是 `AbilityStageContext`,而非 `UIAbilityContext`。会话、视图、事件、崩溃、存储等功能在它之上都能正常工作。Content / Feedback 浮层使用的外部 URL 跳转能力(依赖 `startAbility`)需要 `UIAbilityContext`;如需在未来版本启用这些模块,请在某个 UIAbility 的 `onForeground` 中调用 `setExternalUrlOpener(...)`。

### 配置项

`CountlyConfig` 通过**分组子配置**(`config.logging`、`config.consent`、`config.network`、`config.deviceId`、`config.location`、`config.crashes`、`config.views`、`config.sessions`、`config.events`、`config.userProfile`、`config.remoteConfig`、`config.experimental`)暴露链式 setter。`CountlyConfig` 顶层方法仅有 `setAppVersion`、`setMetricOverride`、`setSDKBehaviorSettings`、`disableSDKBehaviorSettingsUpdates`。

```typescript
import { Countly, CountlyConfig, CountlyFeature, LogLevel } from 'countly-sdk-hos';

const config = new CountlyConfig(this.context, 'https://YOUR_SERVER', 'YOUR_APP_KEY')
  .setAppVersion('1.4.2')                                 // 应用版本
  .setMetricOverride({ '_device': 'Custom Device' });     // 覆盖默认设备指标

// 日志
config.logging
  .enableLogging()
  .setMinLevel(LogLevel.DEBUG);

// 设备 ID
config.deviceId.setId('custom-device-id');

// 用户授权
config.consent
  .setRequiresConsent(true)
  .setEnabled([CountlyFeature.SESSIONS, CountlyFeature.EVENTS]);

// 位置信息
config.location.set('CN', 'Beijing', '39.9,116.4', null);

// 网络(自定义请求头、salt、队列上限、离线模式、健康检查)
config.network
  .setParameterTamperingProtectionSalt('your-salt')
  .addCustomNetworkRequestHeaders({ 'X-Custom-Header': 'value' });

// 崩溃上报
config.crashes
  .enableCrashReporting()
  .setCustomCrashSegmentation({ 'buildType': 'release' })
  .enableRecordAllThreadsWithCrash();

// 视图追踪
config.views
  .enableAutomaticViewTracking()
  .enableAutomaticViewShortNames();

await Countly.initShared(config);
```

### 记录事件

```typescript
const events = Countly.sharedInstance().events;

// 记录简单事件
await events.recordEvent('login');

// 携带分段(segmentation)
await events.recordEvent('level_completed', {
  level: 2,
  score: 500
});

// 完整字段:分段 + 计数 + 求和 + 时长
await events.recordEvent('purchase', { screen: 'main' }, 1, 2.99, 30);

// 计时事件
events.startEvent('checkout');
await events.endEvent('checkout', { status: 'completed' }, 1, 0);
```

> **建议:** 事件 key 与分段 key 推荐使用英文 ASCII 命名,以便在 Countly 控制台分析、过滤、对比时与跨平台的同名事件保持一致。如确需中文,请保持团队内部一致命名,避免相同语义出现多种 key。

### 记录视图

```typescript
const views = Countly.sharedInstance().views;

// 自动结束的视图(进入下一个视图时自动 stop)
await views.startAutoStoppedView('HomeScreen');

// 切换到下一个视图(自动结束 HomeScreen)
await views.startAutoStoppedView('SettingsScreen');

// 手动管理的视图
const id = await views.startView('Checkout');
await views.stopViewWithID(id!, { completed: true });
// 或按名称:
// await views.stopViewWithName('Checkout');
```

### 用户画像

```typescript
const userProfile = Countly.sharedInstance().userProfile;

// 设置预定义 / 自定义属性
userProfile.setProperties({
  name: 'Jane Doe',
  email: 'jane@example.com',
  byear: 1990,
  tier: 'premium'
});

// 修改器(modifier)操作
userProfile.increment('launches');
userProfile.incrementBy('points', 50);
userProfile.multiply('score', 2);
userProfile.saveMax('highScore', 100);

// 数组类操作
userProfile.push('badges', 'gold');
userProfile.pushUnique('tags', 'beta');
userProfile.pull('tags', 'alpha');

// save() 触发上传
await userProfile.save();
```

### 崩溃上报

```typescript
// 显式上报已捕获的异常
try {
  doRiskyWork();
} catch (err) {
  await Countly.sharedInstance().crashes.recordHandledException(err as Error, {
    'area': 'checkout'
  });
}

// 添加面包屑(breadcrumb)以记录崩溃前的状态
Countly.sharedInstance().crashes.addCrashBreadcrumb('entered-checkout');
Countly.sharedInstance().crashes.addCrashBreadcrumb('tapped-pay');
```

### 用户授权管理

```typescript
// 授权指定功能
Countly.sharedInstance().consent.giveConsent([
  CountlyFeature.VIEWS,
  CountlyFeature.CRASHES
]);

// 撤销授权
Countly.sharedInstance().consent.removeConsent([CountlyFeature.LOCATION]);

// 一键授权全部功能
Countly.sharedInstance().consent.giveConsentAll();
```

### 设备 ID 管理

```typescript
const deviceId = Countly.sharedInstance().deviceId;

// 推荐:由 SDK 自动选择是否合并旧档案。
await deviceId.setID('new-user-id');

// 高级用法:
// 在服务端合并旧档案与新档案
await deviceId.changeWithMerge('new-user-id');
// 视为新用户、清空授权
await deviceId.changeWithoutMerge('fresh-user');

// 启用临时 ID 模式(本地排队直到设置真正的 ID)
await deviceId.enableTemporaryIdMode();
```

### 多实例支持

```typescript
import { Countly, CountlyConfig } from 'countly-sdk-hos';

const cfgA = new CountlyConfig(this.context, 'URL_A', 'APP_KEY_A');
const cfgB = new CountlyConfig(this.context, 'URL_B', 'APP_KEY_B');

// 创建多个实例
const instanceA = await Countly.createInstance('analytics', cfgA);
const instanceB = await Countly.createInstance('crash', cfgB);

// 分别使用
await instanceA.events.recordEvent('login');
await instanceB.crashes.recordHandledException(new Error('demo'));
```

## 中国大陆部署小贴士

* **服务端地址:** Countly 是自托管产品,请将 `YOUR_SERVER` 替换为您自己部署的服务地址(中国大陆境内私有部署可避免跨境延迟与合规问题)。
* **Push:** 中国大陆环境推荐使用 HMS Push 推送服务。SDK 中 `MessagingProvider.HMS` 已对应该路径。
* **崩溃栈:** 崩溃栈与日志默认使用英文(JS/V8 栈格式),便于跨团队排查与社区检索。
* **大请求体:** 含中文事件名 / 分段值的长 URL 在部分运营商网络可能被中间盒截断,可通过 `config.network` 中的相关开关启用 POST 兜底。
* **授权弹窗:** GDPR / 个保法对应的授权流程可使用 `requiresConsent + giveConsent / removeConsent` 实现。授权撤销时 SDK 会自动结束当前会话(`end_session`)并发送授权快照。

## 安全

安全对我们至关重要。如发现任何安全问题,请将信息以负责任的方式发送至 <security@countly.com>,**请勿** 通过 GitHub Issue 公开披露。

## 推广徽章

如果您喜欢 Countly,可以 [选择我们的徽章之一](https://countly.com/brand-assets) 添加到您的项目中,链接回 Countly 让更多人发现这款优秀的平台。

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/dark.svg?v2" alt="Countly - Product Analytics" /></a>

```html
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/dark.svg" alt="Countly - Product Analytics" /></a>
```

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/light.svg?v2" alt="Countly - Product Analytics" /></a>

```html
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/light.svg" alt="Countly - Product Analytics" /></a>
```

## 如何获得帮助?

很高兴您愿意了解!社区支持、功能建议与日常交流请加入 [我们的 Discord 服务器](https://discord.gg/countly)。

我们也活跃在 [Twitter](https://twitter.com/gocountly) 与 [LinkedIn](https://www.linkedin.com/company/countly),欢迎关注 Countly 的最新动态。
