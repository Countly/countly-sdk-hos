![API](https://img.shields.io/badge/API-12%2B-brightgreen.svg?style=flat)
![Status](https://img.shields.io/badge/status-experimental-orange.svg?style=flat)

**English** · [简体中文](./README-zh-CN.md)

# Countly HarmonyOS SDK

This repository contains the **experimental** Countly HarmonyOS SDK, which can be integrated into HarmonyOS NEXT Stage-model applications written in ArkTS. The Countly HarmonyOS SDK is intended to be used with [Countly Lite](https://countly.com/lite), [Countly Flex](https://countly.com/flex), [Countly Enterprise](https://countly.com/enterprise).

> **Experimental.** This SDK is under active development. Public APIs follow the Countly cross-SDK conventions.

## What is Countly?

[Countly](https://countly.com) is a product analytics solution and innovation enabler that helps teams track product performance and customer journey and behavior across [mobile](https://countly.com/mobile-analytics), [web](https://countly.com/web-analytics), and [desktop](https://countly.com/desktop-analytics) applications. [Ensuring privacy by design](https://countly.com/privacy-by-design), Countly allows you to innovate and enhance your products to provide personalized and customized customer experiences, and meet key business and revenue goals.

Track, measure, and take action - all without leaving Countly.

* **Questions or feature requests?** [Join the Countly Community on Discord](https://discord.gg/countly)
* **Looking for the Countly Server?** [Countly Server repository](https://github.com/Countly/countly-server)
* **Looking for other Countly SDKs?** [An overview of all Countly SDKs for mobile, web and desktop](https://support.count.ly/hc/en-us/articles/360037236571-Downloading-and-Installing-SDKs#h_01H9QCP8G5Y9PZJGERZ4XWYDY9)

## Integrating Countly SDK in your projects

For a detailed description on how to use this SDK [check out our documentation](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS).

For information about how to add the SDK to your project, please check [this section of the documentation](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS#h_01HND_ADDSDK).

You can find minimal SDK integration information for your project in [this section of the documentation](https://support.countly.com/hc/en-us/articles/27089854037276-HarmonyOS#h_01HND_MINIMAL).

For an example integration of this SDK, you can have a look [here](https://github.com/Countly/countly-sdk-hos/tree/staging/entry/src/main/ets).

This SDK supports the following features:
* [Analytics](https://support.count.ly/hc/en-us/articles/4431589003545-Analytics)
* [User Profiles](https://support.count.ly/hc/en-us/articles/4403281285913-User-Profiles)
* [Crash Reports](https://support.count.ly/hc/en-us/articles/4404213566105-Crashes-Errors)
* [A/B Testing](https://support.count.ly/hc/en-us/articles/4416496362393-A-B-Testing-)

## Installation

In the `dependencies:` section of your module-level `oh-package.json5`, add the following line:

```json
{
  "dependencies": {
    "countly-sdk-hos": "^26.1.0"
  }
}
```

### Supported platforms

* **HarmonyOS NEXT 5.0 and later** (API level **12+**)
* ArkTS strict mode (the SDK is built and tested against the strict ruleset)
* Stage Model UIAbilities only (FA Model is not supported)

### Required permissions

The SDK needs access to the network. Ensure the following permissions are in your `module.json5`:

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

## Usage

### Initialization

**Recommended:** initialize the SDK from an `AbilityStage`.`AbilityStage.onCreate` runs once per HAP module process, **before any UIAbility is created**, so the SDK's `applicationStateChange` and `abilityLifecycle` subscriptions are registered ahead of the platform's first foreground transitions — no cold-boot session/view drops.

Create `entry/src/main/ets/myabilitystage/MyAbilityStage.ets`:

```typescript
import AbilityStage from '@ohos.app.ability.AbilityStage';
import { Countly, CountlyConfig } from 'countly-sdk-hos';

export default class MyAbilityStage extends AbilityStage {
  onCreate(): void {
    const config = new CountlyConfig(
      this.context,          // common.Context (AbilityStageContext here)
      'https://YOUR_SERVER', // your Countly server URL
      'YOUR_APP_KEY'         // your app key from the dashboard
    );
    // onCreate is synchronous-void: fire-and-forget the async init.
    Countly.initShared(config).catch((err) => console.error(`Countly init failed: ${err}`));
  }
}
```

Wire the AbilityStage at the module level in `entry/src/main/module.json5`:

```json
{
  "module": {
    "srcEntry": "./ets/myabilitystage/MyAbilityStage.ets"
  }
}
```

With this in place, your `EntryAbility` carries no SDK code — no `Countly.initShared` call, no `onForeground` / `onBackground` overrides.

**Alternative — UIAbility init.** You can also initialize from `EntryAbility.onCreate` if you don't want to add an `AbilityStage`. The SDK still works, but the platform's cold-boot foreground transition may fire before the long async `init()` chain (storage + device-id + module inits) completes — in that race, the very first session and auto-view of a cold launch may be missed. Subsequent foreground/background cycles are unaffected. For a multi-window or production-grade integration, prefer `AbilityStage`.

```typescript
import UIAbility from '@ohos.app.ability.UIAbility';
import { Countly, CountlyConfig } from 'countly-sdk-hos';

export default class EntryAbility extends UIAbility {
  async onCreate(want, launchParam): Promise<void> {
    const config = new CountlyConfig(this.context, 'https://YOUR_SERVER', 'YOUR_APP_KEY');
    await Countly.initShared(config);
    // Lifecycle is auto-wired by the SDK — no onForeground / onBackground overrides needed.
  }
}
```

> **Note on AbilityStageContext.** The context passed into `CountlyConfig` from an `AbilityStage` is an `AbilityStageContext`, not a `UIAbilityContext`. Sessions, views, events, crashes, and storage all work fine off it. The external-URL-opener path used by Content / Feedback overlays needs a `UIAbilityContext` (for `startAbility`); if you re-enable those modules in a future build, call `setExternalUrlOpener(...)` from a UIAbility's `onForeground`.

### Configuration Options

`CountlyConfig` exposes fluent setters as **grouped sub-configs** (`config.logging`, `config.consent`, `config.network`, `config.deviceId`, `config.location`, `config.crashes`, `config.views`, `config.sessions`, `config.events`, `config.userProfile`, `config.remoteConfig`, `config.experimental`). Top-level methods on `CountlyConfig` are limited to `setAppVersion`, `setMetricOverride`, `setSDKBehaviorSettings`, and `disableSDKBehaviorSettingsUpdates`.

```typescript
import { Countly, CountlyConfig, CountlyFeature, LogLevel } from 'countly-sdk-hos';

const config = new CountlyConfig(this.context, 'https://YOUR_SERVER', 'YOUR_APP_KEY')
  .setAppVersion('1.4.2')                                 // App version
  .setMetricOverride({ '_device': 'Custom Device' });     // Override device metrics

// Logging
config.logging
  .enableLogging()
  .setMinLevel(LogLevel.DEBUG);

// Device ID
config.deviceId.setId('custom-device-id');

// Consent
config.consent
  .setRequiresConsent(true)
  .setEnabled([CountlyFeature.SESSIONS, CountlyFeature.EVENTS]);

// Location
config.location.set('US', 'New York', '40.7,-74.0', null);

// Networking (custom headers, salt, queue limits, offline mode, health check)
config.network
  .setParameterTamperingProtectionSalt('your-salt')
  .addCustomNetworkRequestHeaders({ 'X-Custom-Header': 'value' });

// Crash Reporting
config.crashes
  .enableCrashReporting()
  .setCustomCrashSegmentation({ 'buildType': 'release' })
  .enableRecordAllThreadsWithCrash();

// Views
config.views
  .enableAutomaticViewTracking()
  .enableAutomaticViewShortNames();

await Countly.initShared(config);
```

### Recording Events

```typescript
const events = Countly.sharedInstance().events;

// Record a simple event
await events.recordEvent('login');

// Record event with segmentation
await events.recordEvent('level_completed', {
  level: 2,
  score: 500
});

// Record event with segmentation, count, sum, and duration
await events.recordEvent('purchase', { screen: 'main' }, 1, 2.99, 30);

// Timed events
events.startEvent('checkout');
await events.endEvent('checkout', { status: 'completed' }, 1, 0);
```

### Recording Views

```typescript
const views = Countly.sharedInstance().views;

// Start an auto-stopped view (automatically ends when another view starts)
await views.startAutoStoppedView('HomeScreen');

// Navigate to another view (automatically ends HomeScreen)
await views.startAutoStoppedView('SettingsScreen'); 

// Manual views
const id = await views.startView('Checkout');
await views.stopViewWithID(id!, { completed: true });
// or by name:
// await views.stopViewWithName('Checkout');
```

### User Profiles

```typescript
const userProfile = Countly.sharedInstance().userProfile;

// Set named/custom user properties
userProfile.setProperties({
  name: 'Jane Doe',
  email: 'jane@example.com',
  byear: 1990,
  tier: 'premium'
});

// Property modifiers
userProfile.increment('launches');
userProfile.incrementBy('points', 50);
userProfile.multiply('score', 2);
userProfile.saveMax('highScore', 100);

// Array operations
userProfile.push('badges', 'gold');
userProfile.pushUnique('tags', 'beta');
userProfile.pull('tags', 'alpha');

// Save changes to flush them to the server
await userProfile.save();
```

### Crash Reporting

```typescript
// Explicitly record handled exceptions
try {
  doRiskyWork();
} catch (err) {
  await Countly.sharedInstance().crashes.recordHandledException(err as Error, {
    'area': 'checkout'
  });
}

// Add breadcrumbs to track the state leading up to a crash
Countly.sharedInstance().crashes.addCrashBreadcrumb('entered-checkout');
Countly.sharedInstance().crashes.addCrashBreadcrumb('tapped-pay');
```

### Consent Management

```typescript
// Grant consent for specific features
Countly.sharedInstance().consent.giveConsent([
  CountlyFeature.VIEWS, 
  CountlyFeature.CRASHES
]);

// Revoke consent
Countly.sharedInstance().consent.removeConsent([CountlyFeature.LOCATION]);

// Grant consent for all features
Countly.sharedInstance().consent.giveConsentAll();
```

### Device ID Management

```typescript
const deviceId = Countly.sharedInstance().deviceId;

// Recommended: SDK picks the correct merge semantics automatically.
await deviceId.setID('new-user-id');

// Advanced:
// Merges old + new profiles on server
await deviceId.changeWithMerge('new-user-id');   
// Treats as new user, clears consent
await deviceId.changeWithoutMerge('fresh-user'); 

// Enable Temporary ID mode (queues data locally until a real ID is provided)
await deviceId.enableTemporaryIdMode();
```

### Multi-Instance Support

```typescript
import { Countly, CountlyConfig } from 'countly-sdk-hos';

const cfgA = new CountlyConfig(this.context, 'URL_A', 'APP_KEY_A');
const cfgB = new CountlyConfig(this.context, 'URL_B', 'APP_KEY_B');

// Initialize multiple instances
const instanceA = await Countly.createInstance('analytics', cfgA);
const instanceB = await Countly.createInstance('crash', cfgB);

// Use specific instances
await instanceA.events.recordEvent('login');
await instanceB.crashes.recordHandledException(new Error('demo'));
```

## Security

Security is very important to us. If you discover any issue regarding security, please disclose the information responsibly by sending an email to <security@countly.com> and **not by creating a GitHub issue**.

## Badges

If you like Countly, [why not use one of our badges](https://countly.com/brand-assets) and give a link back to us so others know about this wonderful platform?

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/dark.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="[https://count.ly/f/badge](https://count.ly/f/badge)" rel="nofollow"><img style="width:145px;height:60px" src="[https://countly.com/badges/dark.svg](https://countly.com/badges/dark.svg)" alt="Countly - Product Analytics" /></a>
```

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://countly.com/badges/light.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="[https://count.ly/f/badge](https://count.ly/f/badge)" rel="nofollow"><img style="width:145px;height:60px" src="[https://countly.com/badges/light.svg](https://countly.com/badges/light.svg)" alt="Countly - Product Analytics" /></a>
```

## How can I help you with your efforts?

Glad you asked! For community support, feature requests, and engaging with the Countly Community, please join us at [our Discord Server](https://discord.gg/countly). We're excited to have you there!

Also, we are on [Twitter](https://twitter.com/gocountly) and [LinkedIn](https://www.linkedin.com/company/countly) if you would like to keep up with Countly related updates.