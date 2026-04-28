import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import {
  ConsentChangeSource,
  CountlyFeature,
  MessagingProvider,
  PushTestMode,
  PushActionHandler,
  SegmentationMap
} from '../../types/Types';

/**
 * Debounce window: the server doesn't need the same token resent more than
 * once a minute. Prevents chatty callers (or a hostile one) from spamming the
 * `/i?token_session=1` endpoint — which is otherwise cheap to abuse since it
 * bypasses the normal event/session batching.
 */
const TOKEN_DEBOUNCE_MS: number = 60 * 1000;

/** Storage keys for the currently-known token + provider. */
const STORAGE_KEY_TOKEN: string = 'cly_push_token';
const STORAGE_KEY_PROVIDER: string = 'cly_push_provider';

/**
 * Push notifications module. Handles:
 *   - Token state persistence (so a restart doesn't re-register)
 *   - Token debouncing (60s window per dev guide)
 *   - `/i?token_session=1` registration requests
 *   - `[CLY]_push_action` internal event recording (body taps + button taps)
 *   - Action-handler dispatch + allowlist enforcement
 *
 * The actual HMS Push Kit call (`@kit.PushKit.pushService.getToken()`) is NOT
 * wired here — it belongs in the host's ability. The host calls
 * `onTokenRefresh(token, provider)` from its HMS token-refresh callback. This
 * keeps the SDK free of a hard dependency on HMS and testable without a device.
 */
export class ModulePush extends ModuleBase {
  private core: SdkCore;
  private actionHandler: PushActionHandler | null = null;
  private allowedIntentTargets: string[] = [];
  private testMode: PushTestMode = PushTestMode.PRODUCTION;
  private sendTokenAlways: boolean = false;

  private lastToken: string = '';
  private lastProvider: MessagingProvider = MessagingProvider.HMS;
  private lastSentAtMs: number = 0;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModulePush] Initialising');
    this.core = core;
    // Config → module fields (copied so post-init CountlyConfig mutation
    // doesn't retroactively affect an already-built instance).
    this.lastProvider = config.pushProvider;
    this.testMode = config.pushTestMode;
    this.sendTokenAlways = config.pushSendTokenAlways;
    this.actionHandler = config.pushActionHandler;
    this.allowedIntentTargets = config.pushAllowedIntentTargets.slice();
  }

  public override async onInit(): Promise<void> {
    // Rehydrate last-known token so we can resend on consent grants / device-id
    // changes without having to re-acquire from the platform.
    if (!this.config.storage) return;
    this.lastToken = await this.config.storage.getString(STORAGE_KEY_TOKEN, '');
    const storedProvider: string = await this.config.storage.getString(STORAGE_KEY_PROVIDER, '');
    if (storedProvider === MessagingProvider.FCM) this.lastProvider = MessagingProvider.FCM;
    else if (storedProvider === MessagingProvider.APN) this.lastProvider = MessagingProvider.APN;
    else if (storedProvider === MessagingProvider.HMS) this.lastProvider = MessagingProvider.HMS;
    // else: keep the config-configured default set in the constructor.
  }

  /**
   * Called by the host when the platform pushes a new/refreshed token. Matches
   * `CountlyInstance.onTokenRefresh` per the dev guide; debounced on identical
   * (token, provider) pairs within TOKEN_DEBOUNCE_MS.
   */
  public async onTokenRefresh(token: string, provider: MessagingProvider): Promise<void> {
    if (Utils.isNullOrEmpty(token)) {
      this.config.logger.w('[ModulePush] onTokenRefresh, token is null/empty — use clearPushNotificationToken() to unregister');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.PUSH) && !this.sendTokenAlways) {
      this.config.logger.v('[ModulePush] onTokenRefresh, no push consent — token stashed, will send when granted');
      await this.persistToken(token, provider);
      return;
    }
    const now: number = Date.now();
    if (token === this.lastToken && provider === this.lastProvider && (now - this.lastSentAtMs) < TOKEN_DEBOUNCE_MS) {
      this.config.logger.d('[ModulePush] onTokenRefresh, duplicate token within debounce window — skipped');
      return;
    }
    await this.persistToken(token, provider);
    await this.sendTokenSession(token, provider);
    this.lastSentAtMs = now;
  }

  /**
   * Manually resend the last-known token to the server. Useful after a device
   * ID change (with merge) where the server needs to re-associate the token.
   */
  public async recordPushNotificationToken(): Promise<void> {
    if (Utils.isNullOrEmpty(this.lastToken)) {
      this.config.logger.w('[ModulePush] recordPushNotificationToken, no token yet — call onTokenRefresh first');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.PUSH) && !this.sendTokenAlways) {
      this.config.logger.v('[ModulePush] recordPushNotificationToken, no push consent — skipped');
      return;
    }
    await this.sendTokenSession(this.lastToken, this.lastProvider);
    this.lastSentAtMs = Date.now();
  }

  /**
   * Unregister the device on the server by sending an empty token. The stored
   * token is cleared so a later consent grant doesn't resend it.
   */
  public async clearPushNotificationToken(): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.PUSH) && !this.sendTokenAlways) {
      this.config.logger.v('[ModulePush] clearPushNotificationToken, no push consent — skipped');
      return;
    }
    // Send empty token_session to unregister.
    await this.sendTokenSession('', this.lastProvider);
    this.lastToken = '';
    this.lastSentAtMs = 0;
    if (this.config.storage) {
      await this.config.storage.remove(STORAGE_KEY_TOKEN);
    }
  }

  /**
   * Set by CountlyInstance to let this module push `[CLY]_push_action` events
   * through ModuleEvents (consent gating + immediate flush happen there).
   * Kept as an injected callback so ModulePush doesn't depend on ModuleEvents.
   */
  private pushActionRecorder: ((seg: SegmentationMap) => Promise<void>) | null = null;
  public setPushActionRecorder(fn: (seg: SegmentationMap) => Promise<void>): void {
    this.pushActionRecorder = fn;
  }

  /**
   * Records a `[CLY]_push_action` event for a notification body/button tap and
   * optionally opens the action URL. Consent + immediate flush are applied
   * inside the events pipeline. `buttonIndex=0` = notification body tap;
   * `1..n` = action button index from the payload's `c.b` array.
   *
   * URL handling order:
   *   1. If `actionHandler` returns true → SDK does NOT open the URL.
   *   2. If a non-empty allowlist is set, URL must match a prefix entry.
   *   3. Actual URL opening is delegated via `openUrlFn` so tests can verify
   *      without launching anything.
   */
  public async recordPushActionEvent(
    notificationId: string,
    buttonIndex: number,
    url: string | null,
    openUrlFn: ((url: string) => void) | null
  ): Promise<void> {
    if (Utils.isNullOrEmpty(notificationId)) {
      this.config.logger.w('[ModulePush] recordPushActionEvent, notificationId is null/empty — dropped');
      return;
    }
    const seg: SegmentationMap = {};
    seg['i'] = notificationId;
    seg['b'] = buttonIndex;
    // Platform code 'h' = HarmonyOS. Dev guide defines a/i/m for the three
    // existing platforms; 'h' is the natural continuation.
    seg['p'] = 'h';
    if (this.pushActionRecorder !== null) {
      await this.pushActionRecorder(seg);
    } else {
      this.config.logger.w('[ModulePush] recordPushActionEvent, no recorder wired — event dropped');
    }
    if (url === null || url.length === 0) return;
    if (this.actionHandler !== null) {
      try {
        const handled: boolean = this.actionHandler(notificationId, buttonIndex, url);
        if (handled) return;
      } catch (err) {
        this.config.logger.e(`[ModulePush] recordPushActionEvent, actionHandler threw: ${err}`);
      }
    }
    if (!this.isUrlAllowed(url)) {
      this.config.logger.w(`[ModulePush] recordPushActionEvent, url blocked by allowlist: ${this.redactUrl(url)}`);
      return;
    }
    if (openUrlFn !== null) {
      try { openUrlFn(url); }
      catch (err) { this.config.logger.e(`[ModulePush] recordPushActionEvent, openUrlFn threw: ${err}`); }
    }
  }

  public override async onConsentChanged(added: string[], _removed: string[], _source: ConsentChangeSource): Promise<void> {
    // On push consent granted, try to register the stashed token.
    if (added.indexOf(CountlyFeature.PUSH) !== -1 && this.lastToken.length > 0) {
      await this.sendTokenSession(this.lastToken, this.lastProvider);
      this.lastSentAtMs = Date.now();
    }
  }

  public override async onDeviceIdChangedMerged(_oldId: string, _newId: string): Promise<void> {
    // Token stays the same; server needs re-association under the new id.
    if (this.lastToken.length > 0 && (this.core.consentModule.hasConsent(CountlyFeature.PUSH) || this.sendTokenAlways)) {
      await this.sendTokenSession(this.lastToken, this.lastProvider);
      this.lastSentAtMs = Date.now();
    }
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    // New user — old token should not be associated with them. Clear on
    // server by sending empty token under the new id, then drop locally.
    // Consent has already been reset by the caller, so this is best-effort.
    if (this.lastToken.length > 0) {
      // Skip the consent check here: the caller just cleared all consents and
      // we want the server to know the previous token is no longer valid for
      // the new user. Same rationale as the location erasure on revoke.
      await this.sendTokenSession('', this.lastProvider);
    }
    this.lastToken = '';
    this.lastSentAtMs = 0;
    if (this.config.storage) {
      await this.config.storage.remove(STORAGE_KEY_TOKEN);
      await this.config.storage.remove(STORAGE_KEY_PROVIDER);
    }
  }

  // -- Internals --

  private async persistToken(token: string, provider: MessagingProvider): Promise<void> {
    this.lastToken = token;
    this.lastProvider = provider;
    if (this.config.storage) {
      await this.config.storage.setString(STORAGE_KEY_TOKEN, token);
      await this.config.storage.setString(STORAGE_KEY_PROVIDER, provider);
    }
  }

  private async sendTokenSession(token: string, provider: MessagingProvider): Promise<void> {
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['token_session'] = '1';
    params['token_provider'] = provider;
    params['test_mode'] = String(this.testMode);
    // Use a provider-scoped token key per dev guide ("PLATFORM_token"). For
    // HarmonyOS/HMS the convention is `harmony_token`; for cross-provider
    // integrators we still name by provider.
    const tokenKey: string = ModulePush.tokenKeyForProvider(provider);
    params[tokenKey] = token;
    const body: string = Utils.buildQueryString(params);
    await this.core.requestQueue.enqueue(body);
  }

  private static tokenKeyForProvider(p: MessagingProvider): string {
    if (p === MessagingProvider.FCM) return 'android_token';
    if (p === MessagingProvider.APN) return 'ios_token';
    return 'harmony_token';
  }

  /**
   * Allowlist check: an empty list means everything is allowed (per dev guide
   * default). A non-empty list is matched by scheme prefix OR full-URL prefix.
   */
  private isUrlAllowed(url: string): boolean {
    if (this.allowedIntentTargets.length === 0) return true;
    for (let i = 0; i < this.allowedIntentTargets.length; i++) {
      const entry: string = this.allowedIntentTargets[i];
      if (url.startsWith(entry)) return true;
    }
    return false;
  }

  /** Strip query/fragment from a URL before logging so we don't leak tokens. */
  // Replace nested ternary + confusing `cut` naming with a single earliest-delim scan.
  private redactUrl(url: string): string {
    let cut: number = url.length;
    const q: number = url.indexOf('?');
    if (q !== -1 && q < cut) cut = q;
    const h: number = url.indexOf('#');
    if (h !== -1 && h < cut) cut = h;
    return url.substring(0, cut);
  }
}
