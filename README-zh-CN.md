![API](https://img.shields.io/badge/API-12%2B-brightgreen.svg?style=flat)

[English](./README.md) · **简体中文**

# Countly HarmonyOS SDK

本仓库包含 Countly HarmonyOS SDK，可集成到使用 ArkTS 编写的 HarmonyOS NEXT Stage 模型应用中。Countly HarmonyOS SDK 适用于 [Countly Lite](https://countly.com/lite)、[Countly Flex](https://countly.com/flex) 与 [Countly Enterprise](https://countly.com/enterprise)。

## Countly 是什么？

[Countly](https://countly.com) 是面向 [移动端](https://countly.com/mobile-analytics)、[Web 端](https://countly.com/web-analytics) 与 [桌面端](https://countly.com/desktop-analytics) 应用的产品分析与创新使能平台,帮助团队追踪产品表现、用户旅程与行为。Countly [秉持隐私优先的设计理念](https://countly.com/privacy-by-design),让您在保护用户隐私的前提下持续优化产品、提供个性化体验,并达成关键业务与营收目标。

追踪、度量、行动, 在 Countly 中一站完成。

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

SDK 以预编译的 **`.har`** 形式随每个 [GitHub Release](https://github.com/Countly/countly-sdk-hos/releases) 发布。发布到 ohpm 的计划仍在推进中,目前尚未上架。

1. 从最新 Release 下载 `countly-sdk-hos-<version>.har`。可选:使用同 Release 中的 `.sha256` 校验文件完整性:

   ```bash
   shasum -a 256 -c countly-sdk-hos-<version>.har.sha256
   ```

2. 将 `.har` 放入应用模块中,例如 `entry/libs/countly-sdk-hos-<version>.har`。

3. 在模块级 `oh-package.json5` 中通过 `file:` 引用:

   ```json5
   {
     "dependencies": {
       "countly-sdk-hos": "file:./libs/countly-sdk-hos-26.1.0.har"
     }
   }
   ```

4. 运行 `ohpm install`(或在 DevEco Studio 中同步)。按常规方式导入:

   ```typescript
   import { Countly, CountlyConfig } from 'countly-sdk-hos';
   ```

> 一旦 SDK 上架 ohpm,即可将 `file:` 引用替换为常规的 `"countly-sdk-hos": "^26.1.0"`。

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

**推荐方式:** 在 `AbilityStage` 中初始化 SDK。`AbilityStage.onCreate` 在每个 HAP 模块进程中只会执行一次,**且早于任何 UIAbility 创建**,因此 SDK 的 `applicationStateChange` 与 `abilityLifecycle` 订阅会在平台首次前台切换之前完成注册, 不会丢失冷启动的会话与首次视图。

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
    // onCreate 是同步 void 方法, 异步 init 采用 fire-and-forget。
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

如此一来,`EntryAbility` 不再承担任何 SDK 代码, 无需 `Countly.initShared` 调用,也不需要重写 `onForeground` / `onBackground`。

**备选, UIAbility 初始化。** 如不愿引入 `AbilityStage`,也可在 `EntryAbility.onCreate` 中初始化。SDK 仍可正常运行,但平台的冷启动前台切换可能在异步 `init()` 链(存储 + 设备 ID + 模块初始化)完成之前先行触发, 这种竞态可能导致冷启动的首次会话与首个自动视图丢失。后续前后台切换不受影响。多窗口或生产级集成请优先使用 `AbilityStage`。

```typescript
import UIAbility from '@ohos.app.ability.UIAbility';
import { Countly, CountlyConfig } from 'countly-sdk-hos';

export default class EntryAbility extends UIAbility {
  async onCreate(want, launchParam): Promise<void> {
    const config = new CountlyConfig(this.context, 'https://YOUR_SERVER', 'YOUR_APP_KEY');
    await Countly.initShared(config);
    // 生命周期由 SDK 自动接入, 无需重写 onForeground / onBackground。
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
  .giveAll();

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

运行时的授权接口被有意收窄为二选一:仅暴露 `giveConsentAll`、`removeConsentAll`、
`checkAllConsent`。按功能粒度的授权变更不再对外开放,需要在初始化前通过
`CountlyConfig.consent` 完成。

```typescript
// 一键授权全部功能
Countly.sharedInstance().consent.giveConsentAll();

// 一键撤销全部授权
Countly.sharedInstance().consent.removeConsentAll();

// 查询当前是否所有功能都已授权
const allGranted = Countly.sharedInstance().consent.checkAllConsent();
```

#### 未知授权模式 (Unknown Consent Mode)

当用户尚未做出授权决定、但希望 SDK 先在本地收集数据时,可在初始化时启用未知授权
模式。SDK 仍会记录会话、视图、事件等遥测数据,但请求队列处于暂停状态、网络传输
处于静默状态,在集成方解析未知授权状态之前,这些数据不会发往服务端:

```typescript
config.consent.enableUnknownConsentMode();  // 隐含 setRequiresConsent(true)
```

用户做出决定后,调用以下方法之一:

* `giveConsentAll()` , "授权同意,网络调用可以开始"。解除传输层静默,恢复请求
  队列;在未知阶段缓冲的数据(事件、会话、初始化时的授权快照)会自动发送到
  服务端。SDK 以完整授权状态继续运行。
* `removeConsentAll()` , "授权撤销,清除已收集数据,以无授权状态继续运行"。
  本地缓冲队列被清空,SDK 仅发送一个撤销 `consent=` 快照(所有功能均为 false),
  之后运行时的授权接口被锁定。后续的 `giveConsentAll` / `removeConsentAll`
  调用会记录 `consent is set per init` 并直接返回。SDK 继续运行,但所有受授权
  约束的功能都拒绝执行。如需重新启用授权,集成方必须使用新的 `CountlyConfig`
  重新初始化。

两种解析路径都不会停止实例,无需重新初始化即可继续使用 SDK,撤销路径下
SDK 以"无授权"状态保持运行。

撤销后如需重新启用授权,再次调用 `Countly.initShared(newConfig)`(见下一节)
即可,`initShared` 会自动检测撤销后的锁定状态并用新配置替换现有实例。无需
单独的重新初始化 API,也无需重启应用。

### 停止 / 终止 / 重新初始化

SDK 区分两种关闭实例的方式:

```typescript
// stop() , 内存中停止,但保留磁盘持久化数据。
await Countly.sharedInstance().stop();

// halt() , 停止并清空所有持久化 SDK 数据。用于"删除我的数据"流程。
await Countly.sharedInstance().halt();

// 多实例静态方法(对所有活跃实例:共享 + 命名):
await Countly.stopAll();   // 保留所有存储
await Countly.haltAll();   // 清空所有存储
```

**在不重启应用的前提下进行进程内重新初始化** 使用与启动时相同的 `initShared` 调用:

```typescript
// 健康的共享实例上,initShared 是幂等的:
await Countly.initShared(cfg);     // 创建共享实例
await Countly.initShared(cfg);     // 返回缓存的实例,不替换

// 未知授权模式撤销 / stop / halt 之后,现有共享实例不可再用。
// 下一次 initShared 调用会自动检测并使用新配置重新构建实例:
await Countly.sharedInstance().consent.removeConsentAll();
await Countly.initShared(newCfg);  // 自动替换,新实例、新配置

// 也可以显式调用 stop() 强制切换配置:
await Countly.sharedInstance().stop();
await Countly.initShared(newCfg);  // 由于上一个实例已停止,此处会替换
```

替换只影响共享实例,通过 `createInstance` 创建的命名实例不受影响。持久化
存储跨替换保留(使用 `stop()` 语义),因此任何缓冲请求都会进入新实例并发送。

`stop()` 和 `halt()` 都是**幂等的**(重复调用是安全的)、**按实例隔离**(停止
其中一个实例不影响其他实例)。

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

### 日志

集成阶段可以开启详细日志,稳定后再提升级别:

```typescript
import { LogLevel } from 'countly-sdk-hos';

config.logging
  .enableLogging()             // 将日志输出到 hilog (release 版本默认关闭)
  .setMinLevel(LogLevel.DEBUG); // VERBOSE | DEBUG | INFO | WARNING | ERROR | OFF
```

#### 日志行结构

SDK 的每一条日志由两段前缀加正文组成:

```text
<品牌前缀> <模块标签> <消息正文>
```

* **品牌前缀** 表示这条日志来自哪个 SDK 实例:
  * `[Countly]` ,通过 `Countly.initShared(config)` 创建的共享实例。
  * `[Countly:<name>]` ,通过 `Countly.createInstance('<name>', config)` 创建的命名实例。`<name>` 就是你传给 `createInstance` 的名字,方便在同一个 hilog 流中区分并发的多个实例。
* **模块标签** 表示这条日志来自哪个内部子系统,例如 `[Network]`、`[RequestQueue]`、`[ModuleEvents]`、`[ModuleSessions]`、`[ModuleViews]`、`[ModuleCrashes]`、`[ModuleConsent]`、`[ModuleConfiguration]`、`[ModuleHealthCheck]`、`[ModuleRemoteConfig]`、`[Storage]`,以及 `[Events]`/`[Views]`/`[Crashes]` 等公开门面调用轨迹。

示例:

```text
I  [Countly] [ModuleEvents] recordEvent, queued key='login' count=1 sum=0 dur=0 segmentation={...} queueSize=1
I  [Countly:analytics] [Network] REQUEST SENDING endpoint=/i usePost=true bytes=330 data=...
W  [Countly:analytics] [ModuleSessions] onEnterBackground, unbalanced lifecycle (counter went negative), clamping to 0
```

#### 日志级别与路由

SDK 使用六个逻辑级别,每一个都会映射到对应的 `console.*` 调用,HarmonyOS 再把它转发到 hilog 并附带正确的严重程度列(因此消息中不会再夹带 `[Info]`/`[Debug]` 等文本前缀,hilog 已经显示过了)。

| `LogLevel` | `console` 方法    | hilog 严重程度 |
| ---------- | ----------------- | -------------- |
| `VERBOSE`  | `console.debug`   | D              |
| `DEBUG`    | `console.debug`   | D              |
| `INFO`     | `console.info`    | I              |
| `WARNING`  | `console.warn`    | W              |
| `ERROR`    | `console.error`   | E              |
| `OFF`      | (不调用 console)   | —              |

默认 `minLevel` 为 `DEBUG`。`VERBOSE` 主要用于 SDK 内部排查,会输出大量队列/请求生命周期日志,正常使用时不建议保留。

#### 日志监听器(侧通道)

如果你需要把 SDK 日志转发到自己的接收端(应用内日志面板、远程日志上报等)而不依赖 hilog 过滤,可以设置监听器。它接收的内容与 console 一致,同样受 `minLevel` 过滤:

```typescript
import { LogLevel } from 'countly-sdk-hos';

config.logging.setListener((msg: string, level: LogLevel) => {
  // `msg` 是已经格式化好的整行日志,例如 "[Countly] [Network] REQUEST SENDING ..."
  // `level` 是数值型的 LogLevel,便于按严重程度分流。
  myAppLogger.append(level, msg);
});
```

监听器抛出的异常会被捕获,首次失败时通过 `console.error` 提示一次,之后的失败将被静默以避免递归崩溃。

## 中国大陆部署小贴士

* **服务端地址:** Countly 是自托管产品,请将 `YOUR_SERVER` 替换为您自己部署的服务地址(中国大陆境内私有部署可避免跨境延迟与合规问题)。
* **Push:** 中国大陆环境推荐使用 HMS Push 推送服务。SDK 中 `MessagingProvider.HMS` 已对应该路径。
* **崩溃栈:** 崩溃栈与日志默认使用英文(JS/V8 栈格式),便于跨团队排查与社区检索。
* **大请求体:** 含中文事件名 / 分段值的长 URL 在部分运营商网络可能被中间盒截断,可通过 `config.network` 中的相关开关启用 POST 兜底。
* **授权弹窗:** GDPR / 个保法对应的授权流程可使用 `requiresConsent` 配合运行时的 `giveConsentAll / removeConsentAll` 实现;若希望在用户作出决定之前先在本地缓冲数据,可启用 `enableUnknownConsentMode()`。授权撤销时 SDK 会自动结束当前会话(`end_session`)并发送授权快照。

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
