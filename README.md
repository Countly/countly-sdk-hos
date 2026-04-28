![API](https://img.shields.io/badge/API-11%2B-brightgreen.svg?style=flat)
![Status](https://img.shields.io/badge/status-experimental-orange.svg?style=flat)

# Countly HarmonyOS SDK

This repository contains the **experimental** Countly HarmonyOS SDK, which can be integrated into HarmonyOS / OpenHarmony Stage-model applications written in ArkTS. The Countly HarmonyOS SDK is intended to be used with [Countly Lite](https://countly.com/lite), [Countly Flex](https://countly.com/flex), [Countly Enterprise](https://countly.com/enterprise).

> **Experimental.** This SDK is under active development. Public APIs follow the Countly cross-SDK conventions.

## What is Countly?

[Countly](https://count.ly) is a product analytics solution and innovation enabler that helps teams track product performance and customer journey and behavior across [mobile](https://count.ly/mobile-analytics), [web](https://count.ly/web-analytics),
and [desktop](https://count.ly/desktop-analytics) applications. [Ensuring privacy by design](https://count.ly/privacy-by-design), Countly allows you to innovate and enhance your products to provide personalized and customized customer experiences, and meet key business and revenue goals.

Track, measure, and take action - all without leaving Countly.

* **Questions or feature requests?** [Join the Countly Community on Discord](https://discord.gg/countly)
* **Looking for the Countly Server?** [Countly Server repository](https://github.com/Countly/countly-server)
* **Looking for other Countly SDKs?** [An overview of all Countly SDKs for mobile, web and desktop](https://support.count.ly/hc/en-us/articles/360037236571-Downloading-and-Installing-SDKs#h_01H9QCP8G5Y9PZJGERZ4XWYDY9)

## Integrating Countly SDK in your projects

For a detailed description on how to use this SDK, see the in-repo integration guide at [harmony_doc.md](harmony_doc.md). It covers initialization, configuration, consent, and per-feature usage.

For an example integration of this SDK, see the demo app at [entry/](entry/).

### Minimum requirements

* HarmonyOS / OpenHarmony **API level 11** (ArkTS, Stage model)
* A context-aware module (the SDK uses `@ohos.data.preferences` for persistent storage)

### Quick start

```typescript
import { Countly, CountlyConfig } from 'countly-sdk-hos';

const config = new CountlyConfig(this.context, 'https://try.count.ly', 'APP_KEY')
  .enableLogging();
await Countly.initShared(config);

await Countly.sharedInstance().events.recordEvent('login');
```

## Supported features

This SDK currently supports:

* [Analytics](https://support.count.ly/hc/en-us/articles/4431589003545-Analytics) — events (timed and batched) with segmentation, automatic and manual sessions (including hybrid mode), and view tracking with auto-stop, pause/resume, and global segmentation
* [User Profiles](https://support.count.ly/hc/en-us/articles/4403281285913-User-Profiles) — predefined and custom properties with MongoDB-style modifiers
* [Crash Reports](https://support.count.ly/hc/en-us/articles/4404213566105-Crashes-Errors) — handled and unhandled crashes, breadcrumbs, and a global filter callback
* [A/B Testing](https://support.count.ly/hc/en-us/articles/4416496362393-A-B-Testing-) — remote config fetch and in-memory cache
* Consent management with feature groups and `requiresConsent` enforcement
* Device ID management — SDK-generated, developer-supplied, and temporary/offline modes
* Location tracking — config-time and runtime, with consent-driven erasure
* Multi-instance support — a shared instance plus independent named instances with isolated storage
* Persistent request queue with drop-by-age, GET/POST switching, optional SHA-256 tampering protection, and back-off

## Security

Security is very important to us. If you discover any issue regarding security, please disclose the information responsibly by sending an email to security@count.ly and **not by creating a GitHub issue**.

## Badges

If you like Countly, [why not use one of our badges](https://count.ly/brand-assets) and give a link back to us so others know about this wonderful platform?

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://count.ly/badges/dark.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://count.ly/badges/dark.svg" alt="Countly - Product Analytics" /></a>
```

<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://count.ly/badges/light.svg?v2" alt="Countly - Product Analytics" /></a>

```JS
<a href="https://count.ly/f/badge" rel="nofollow"><img style="width:145px;height:60px" src="https://count.ly/badges/light.svg" alt="Countly - Product Analytics" /></a>
```

## How can I help you with your efforts?

Glad you asked! For community support, feature requests, and engaging with the Countly Community, please join us at [our Discord Server](https://discord.gg/countly). We're excited to have you there!

Also, we are on [Twitter](https://twitter.com/gocountly) and [LinkedIn](https://www.linkedin.com/company/countly) if you would like to keep up with Countly related updates.
