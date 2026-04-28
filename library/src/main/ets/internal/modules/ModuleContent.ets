import display from '@ohos.display';
import i18n from '@ohos.i18n';
import deviceInfo from '@ohos.deviceInfo';
import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { OverlayStore, displayOptionToImmersive } from '../OverlayStore';
import { WindowImmersive } from '../WindowImmersive';
import {
  ConsentChangeSource,
  ContentCallback,
  ContentData,
  ContentPlacement,
  ContentStatus,
  CountlyFeature,
  SegmentationMap,
  WebViewDisplayOption
} from '../../types/Types';

/** Minimum zone interval (dev guide §Content Zone — "Must be greater than 15 seconds"). */
const MIN_ZONE_INTERVAL_SEC: number = 15;

/**
 * After content closes, wait this many timer ticks before the next fetch.
 * Dev guide: "wait period of 2x zone timer interval".
 */
const WAIT_TICKS_AFTER_CLOSE: number = 2;

/**
 * Initial delay before the first fetch after SDK start (dev guide §enterContentZone
 * "4 second initial delay if the SDK was just initialized").
 */
const CONTENT_START_DELAY_MS: number = 4000;

/** Retry tuning for refreshContentZone. Mirrors Android. */
const REFRESH_RETRY_MAX: number = 3;
const REFRESH_RETRY_DELAY_MS: number = 1000;

/** Base URL the content uses to send commands back to the SDK. */
const ACTION_BASE_URL: string = 'https://countly_action_event';
/** Suffix that marks a URL as "open externally, not inside webview". */
const EXTERNAL_LINK_MARKER: string = 'cly_x_int=1';

/** Physical dp-relative screen dimensions used in content request params. */
class ScreenDimensionsDp {
  portraitWidth: number;
  portraitHeight: number;
  landscapeWidth: number;
  landscapeHeight: number;
  density: number;

  constructor(portraitWidth: number, portraitHeight: number, landscapeWidth: number, landscapeHeight: number, density: number) {
    this.portraitWidth = portraitWidth;
    this.portraitHeight = portraitHeight;
    this.landscapeWidth = landscapeWidth;
    this.landscapeHeight = landscapeHeight;
    this.density = density;
  }
}

/**
 * Content Zone module.
 *
 * Architecture (post-refactor to SDK-rendered overlay):
 *   1. Timer periodically fires `/o/sdk/content` fetches.
 *   2. Parsed payloads are published to `OverlayStore` (AppStorage-backed).
 *   3. The library-exported `CountlyContentOverlay` @Component reads that
 *      state and mounts a `Web` component automatically.
 *   4. The overlay calls back into this module via `handleContentUrl()` on
 *      webview URL interception, and `onContentClosed()` when it's dismissed.
 *
 * There is no ContentPresenter interface anymore — the SDK owns the WebView
 * rendering end-to-end via AppStorage. The only integrator requirement is
 * mounting `CountlyOverlayRoot()` somewhere in the UI tree.
 */
export class ModuleContent extends ModuleBase {
  private core: SdkCore;
  private globalCallback: ContentCallback | null = null;

  /** True while the zone is "active" — periodic fetches should run. */
  private shouldFetchContents: boolean = false;
  /** True while an overlay is currently being displayed. */
  private isInContentZone: boolean = false;
  /** Remaining ticks to skip after a content close. */
  private waitTicks: number = 0;
  private zoneIntervalMs: number = 30 * 1000;
  private categories: string[] = [];
  private timerHandle: number = 0;
  private initialStartMs: number = 0;
  private refreshEnabled: boolean = true;
  private displayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;
  private isCurrentlyRetrying: boolean = false;

  /** Origins the postMessage/URL intercept validates against. Server URL always included. */
  private allowedOrigins: string[] = [];

  /**
   * Injected by CountlyInstance so content-emitted analytics events route
   * through the events pipeline (consent gating, force-flush, etc.).
   */
  private contentEventRecorder: ((key: string, seg: SegmentationMap) => Promise<void>) | null = null;
  /** Injected by CountlyInstance to flush queued requests after content events. */
  private queueFlusher: (() => Promise<void>) | null = null;
  /** Injected for opening external links from `action=link` / `cly_x_int=1`. */
  private externalUrlOpener: ((url: string) => void) | null = null;
  /** Returns true when a feedback widget is currently showing — don't overlay content on top. */
  private feedbackShowingProvider: (() => boolean) | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleContent] Initialising');
    this.core = core;
    this.globalCallback = config.contentCallback;
    this.categories = config.contentCategories.slice();
    this.refreshEnabled = config.refreshContentZoneEnabled;
    this.displayMode = config.contentDisplayMode;
    this.allowedOrigins = config.contentAllowedOrigins.slice();
    this.allowedOrigins.push(config.serverUrl);
    const intervalSec: number = Math.max(MIN_ZONE_INTERVAL_SEC + 1, config.contentZoneInterval);
    this.zoneIntervalMs = intervalSec * 1000;
  }

  public override async onInit(): Promise<void> {
    this.initialStartMs = Date.now();
  }

  // -- Dependency injection from CountlyInstance --

  public setContentEventRecorder(fn: (key: string, seg: SegmentationMap) => Promise<void>): void {
    this.contentEventRecorder = fn;
  }

  public setQueueFlusher(fn: () => Promise<void>): void {
    this.queueFlusher = fn;
  }

  public setExternalUrlOpener(fn: ((url: string) => void) | null): void {
    this.externalUrlOpener = fn;
  }

  public setFeedbackShowingProvider(fn: () => boolean): void {
    this.feedbackShowingProvider = fn;
  }

  // -- Public API --

  public async enterContentZone(): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.CONTENT)) {
      this.config.logger.v('[ModuleContent] enterContentZone, no content consent — skipped');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleContent] enterContentZone, temporary device ID mode — skipped');
      return;
    }
    if (this.isInContentZone) {
      this.config.logger.d('[ModuleContent] enterContentZone, already displaying content — skipped');
      return;
    }
    if (this.shouldFetchContents && this.timerHandle !== 0) {
      this.config.logger.d('[ModuleContent] enterContentZone, already in zone with timer — skipped');
      return;
    }
    this.shouldFetchContents = true;
    this.waitTicks = 0;
    const sinceStart: number = Date.now() - this.initialStartMs;
    const initialDelay: number = sinceStart < CONTENT_START_DELAY_MS
      ? (CONTENT_START_DELAY_MS - sinceStart)
      : 0;
    this.startTimer(initialDelay);
  }

  public exitContentZone(): void {
    if (!this.core.consentModule.hasConsent(CountlyFeature.CONTENT)) {
      this.config.logger.v('[ModuleContent] exitContentZone, no content consent — skipped');
      return;
    }
    this.exitContentZoneInternal();
  }

  public async refreshContentZone(): Promise<void> {
    if (!this.refreshEnabled) {
      this.config.logger.d('[ModuleContent] refreshContentZone, refresh is disabled via config — skipped');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.CONTENT)) {
      this.config.logger.v('[ModuleContent] refreshContentZone, no content consent — skipped');
      return;
    }
    if (this.isInContentZone) {
      this.config.logger.d('[ModuleContent] refreshContentZone, content currently displayed — skipped');
      return;
    }
    this.enterContentZoneWithRetries();
  }

  public async previewContent(contentId: string): Promise<void> {
    if (Utils.isNullOrEmpty(contentId)) {
      this.config.logger.w('[ModuleContent] previewContent, contentId is null or empty — skipped');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.CONTENT)) {
      this.config.logger.v('[ModuleContent] previewContent, no content consent — skipped');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleContent] previewContent, temporary device ID mode — skipped');
      return;
    }
    if (this.isInContentZone) {
      this.config.logger.d('[ModuleContent] previewContent, content currently displayed — skipped');
      return;
    }
    await this.fetchContents(contentId);
  }

  // -- Overlay callbacks (invoked by CountlyContentOverlay @Component) --

  /**
   * Called from the overlay component's Web.onLoadIntercept. Returns true if
   * the SDK handled the URL (close / link / event / resize_me / cly_x_int=1)
   * and the webview must block navigation. Returns false for regular page
   * navigation the webview should load normally.
   *
   * This IS the content communication protocol per dev guide §2376.
   */
  public handleContentUrl(url: string): boolean {
    if (Utils.isNullOrEmpty(url)) return false;

    const isCommand: boolean = url.startsWith(ACTION_BASE_URL);
    const isExternalMarker: boolean = url.indexOf(EXTERNAL_LINK_MARKER) !== -1;
    if (!isCommand && !isExternalMarker) return false;

    // Origin validation: command URLs must start with our sentinel base (not
    // configurable by integrators). External-link URLs can be any origin, so
    // we skip the origin check for those — the marker alone is the signal.
    const params: Record<string, string> = ModuleContent.parseQueryParams(url);

    if (isExternalMarker && !isCommand) {
      const cleaned: string = ModuleContent.stripMarker(url, EXTERNAL_LINK_MARKER);
      this.openExternalUrl(cleaned);
      return true;
    }

    // Action event (event / link / resize_me)
    if (params['cly_x_action_event'] === '1') {
      const action: string | undefined = params['action'];
      if (action === 'event') this.dispatchContentEvents(params['event']);
      else if (action === 'link') {
        const link: string | undefined = params['link'];
        if (link !== undefined && link.length > 0) this.openExternalUrl(link);
        else this.config.logger.w('[ModuleContent] action=link with no link param');
      } else if (action === 'resize_me') {
        this.dispatchResizeMe(params['resize_me']);
      } else {
        this.config.logger.w(`[ModuleContent] unknown action '${action}'`);
      }
      if (params['close'] === '1') this.closeOverlayFromProtocol();
      return true;
    }

    // Bare close (no action — just `?close=1` form)
    if (params['close'] === '1') {
      this.closeOverlayFromProtocol();
      return true;
    }

    this.config.logger.w(`[ModuleContent] unrecognized countly command: ${url}`);
    return true;
  }

  /**
   * Called by the overlay component when the user dismisses it (e.g.
   * SDK-drawn close button for placed overlays) or when a load timeout fires.
   * Idempotent — subsequent calls after close are no-ops.
   */
  public onContentClosedByUser(status: ContentStatus, data: Record<string, Object>): void {
    if (!this.isInContentZone) return;
    this.isInContentZone = false;
    this.shouldFetchContents = true;
    this.waitTicks = WAIT_TICKS_AFTER_CLOSE;
    OverlayStore.hideContent();
    WindowImmersive.setContent(false, this.config.context, this.config.logger);
    if (this.globalCallback !== null) {
      try { this.globalCallback(status, data); }
      catch (err) { this.config.logger.e(`[ModuleContent] content callback threw: ${err}`); }
    }
  }

  /** Called by the overlay when its WebView reports a fatal load error or timeout. */
  public onContentLoadTimedOut(): void {
    this.config.logger.w('[ModuleContent] content load timed out — closing overlay');
    this.onContentClosedByUser(ContentStatus.CLOSED, { 'reason': 'timeout' });
  }

  // -- Protocol helpers --

  private dispatchContentEvents(encodedJson: string | undefined): void {
    if (encodedJson === undefined || encodedJson.length === 0) return;
    let parsed: Object;
    try {
      parsed = JSON.parse(encodedJson);
    } catch (err) {
      this.config.logger.w(`[ModuleContent] event action, unparseable JSON: ${err}`);
      return;
    }
    if (!Array.isArray(parsed)) {
      this.config.logger.w('[ModuleContent] event action, expected array');
      return;
    }
    const arr: Object[] = parsed as Object[];
    const recorder = this.contentEventRecorder;
    if (recorder === null) {
      this.config.logger.w('[ModuleContent] event action, no recorder wired');
      return;
    }
    for (let i = 0; i < arr.length; i++) {
      const entry: Object = arr[i];
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue;
      const e: Record<string, Object> = entry as Record<string, Object>;
      const keyRaw: Object | undefined = e['key'];
      if (typeof keyRaw !== 'string' || keyRaw.length === 0) continue;
      // Segmentation may arrive under either "sg" (short form used by some
      // content templates) or "segmentation" (long form). "sg" wins if both
      // are present — matches Android's behaviour (ContentOverlayView.java:591).
      let segRaw: Object | undefined = e['sg'];
      if (segRaw === undefined || segRaw === null) segRaw = e['segmentation'];
      const seg: SegmentationMap = {};
      if (segRaw !== undefined && segRaw !== null && typeof segRaw === 'object' && !Array.isArray(segRaw)) {
        const obj: Record<string, Object> = segRaw as Record<string, Object>;
        const keys: string[] = Object.keys(obj);
        for (let j = 0; j < keys.length; j++) {
          const v: Object = obj[keys[j]];
          if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
            seg[keys[j]] = v as (string | number | boolean);
          } else if (Array.isArray(v) && Utils.isSupportedSegmentationValue(v as (string[] | number[] | boolean[]))) {
            seg[keys[j]] = v as (string[] | number[] | boolean[]);
          }
        }
      }
      recorder(keyRaw, seg).catch((err: Object) => {
        this.config.logger.e(`[ModuleContent] event action, recorder rejected: ${err}`);
      });
    }
    // Flush the queue so content-emitted events go out promptly.
    const flusher = this.queueFlusher;
    if (flusher !== null) {
      flusher().catch((err: Object) => this.config.logger.e(`[ModuleContent] event flush rejected: ${err}`));
    }
  }

  private dispatchResizeMe(encodedJson: string | undefined): void {
    if (encodedJson === undefined || encodedJson.length === 0) return;
    let parsed: Object;
    try { parsed = JSON.parse(encodedJson); }
    catch (err) {
      this.config.logger.w(`[ModuleContent] resize_me, unparseable JSON: ${err}`);
      return;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return;
    const obj: Record<string, Object> = parsed as Record<string, Object>;
    // Coordinates in resize_me are dp (same format as server geo). Convert
    // using the currently-detected density so the overlay uses pixels.
    const dims: ScreenDimensionsDp = this.collectScreenDimensionsDp();
    const portrait: ContentPlacement | null = ModuleContent.placementFromGeo(obj['p'], dims.density);
    const landscape: ContentPlacement | null = ModuleContent.placementFromGeo(obj['l'], dims.density);
    OverlayStore.resizeContent(
      portrait !== null ? portrait.x : 0,
      portrait !== null ? portrait.y : 0,
      portrait !== null ? portrait.width : 0,
      portrait !== null ? portrait.height : 0,
      landscape !== null ? landscape.x : 0,
      landscape !== null ? landscape.y : 0,
      landscape !== null ? landscape.width : 0,
      landscape !== null ? landscape.height : 0
    );
  }

  private closeOverlayFromProtocol(): void {
    this.onContentClosedByUser(ContentStatus.COMPLETED, {});
  }

  /**
   * Prefix-match URL origin against the allowlist. Normalised by stripping
   * trailing slashes off both sides so `https://foo.com` matches
   * `https://foo.com/`, `https://foo.com/a/b`, etc., while
   * `https://foo.com.evil.com` does NOT match `https://foo.com` because the
   * next char after the match must be `/`, `?`, `#`, or end-of-string.
   */
  private isAllowedContentOrigin(url: string): boolean {
    if (url.length === 0) return false;
    for (let i = 0; i < this.allowedOrigins.length; i++) {
      const raw: string = this.allowedOrigins[i];
      if (raw.length === 0) continue;
      const origin: string = Utils.stripTrailingSlashes(raw);
      if (!url.startsWith(origin)) continue;
      if (url.length === origin.length) return true;
      const next: string = url.charAt(origin.length);
      if (next === '/' || next === '?' || next === '#') return true;
      // The start-matched but differs at the next char — e.g.
      // https://foo.com vs https://foo.com.evil.com — reject and continue.
    }
    return false;
  }

  /**
   * Opens an external URL on link actions. Preference order:
   *   1. Integrator-supplied opener (`setExternalUrlOpener`) — full override.
   *   2. SDK-default: launch a `viewData` intent against the UIAbility
   *      context the integrator passed to `CountlyConfig`. Works without
   *      any extra wiring in the typical case.
   */
  private openExternalUrl(url: string): void {
    const opener = this.externalUrlOpener;
    if (opener !== null) {
      try { opener(url); }
      catch (err) { this.config.logger.e(`[ModuleContent] externalUrlOpener threw: ${err}`); }
      return;
    }
    Utils.openExternalUrlViaContext(this.config.context, url, this.config.logger);
  }

  // -- Lifecycle hooks --

  public override async onConsentChanged(_added: string[], removed: string[], _source: ConsentChangeSource): Promise<void> {
    if (removed.indexOf(CountlyFeature.CONTENT) !== -1) {
      this.exitContentZoneInternal();
    }
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    this.exitContentZoneInternal();
  }

  public override async onHalt(): Promise<void> {
    this.exitContentZoneInternal();
  }

  // -- Internals --

  private startTimer(initialDelayMs: number): void {
    this.stopTimer();
    const fireTick = async (): Promise<void> => {
      if (this.waitTicks > 0) { this.waitTicks--; return; }
      if (!this.shouldFetchContents) return;
      if (this.isInContentZone) return;
      try { await this.fetchContents(null); }
      catch (err) { this.config.logger.e(`[ModuleContent] timer tick, fetch rejected: ${err}`); }
    };
    if (initialDelayMs > 0) {
      const firstFire = setTimeout(() => {
        fireTick().then(() => {
          if (!this.shouldFetchContents) return;
          this.timerHandle = setInterval(fireTick, this.zoneIntervalMs) as number;
        });
      }, initialDelayMs);
      this.timerHandle = firstFire as number;
    } else {
      this.timerHandle = setInterval(fireTick, this.zoneIntervalMs) as number;
      fireTick().catch((err: Object) => this.config.logger.e(`[ModuleContent] immediate tick rejected: ${err}`));
    }
  }

  private stopTimer(): void {
    if (this.timerHandle !== 0) {
      clearTimeout(this.timerHandle);
      clearInterval(this.timerHandle);
      this.timerHandle = 0;
    }
  }

  private exitContentZoneInternal(): void {
    this.shouldFetchContents = false;
    this.isInContentZone = false;
    this.waitTicks = 0;
    this.isCurrentlyRetrying = false;
    this.stopTimer();
    OverlayStore.hideContent();
    WindowImmersive.setContent(false, this.config.context, this.config.logger);
  }

  private enterContentZoneWithRetries(): void {
    if (this.isCurrentlyRetrying) {
      this.config.logger.w('[ModuleContent] enterContentZoneWithRetries, already retrying — skipped');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.CONTENT)) return;
    if (this.core.deviceIdModule.isTemporary()) return;
    this.isCurrentlyRetrying = true;
    let attempt: number = 0;

    const tryOnce = (): void => {
      if (!this.isCurrentlyRetrying) return;
      if (this.isInContentZone) { this.isCurrentlyRetrying = false; return; }
      this.stopTimer();
      this.shouldFetchContents = true;
      this.fetchContents(null, () => {
        if (!this.isCurrentlyRetrying) return;
        if (this.isInContentZone) { this.isCurrentlyRetrying = false; return; }
        attempt++;
        if (attempt < REFRESH_RETRY_MAX) {
          setTimeout(tryOnce, REFRESH_RETRY_DELAY_MS);
        } else {
          this.config.logger.w(`[ModuleContent] enterContentZoneWithRetries, ${REFRESH_RETRY_MAX} attempts exhausted`);
          this.isCurrentlyRetrying = false;
        }
      }).catch((err: Object) => {
        this.config.logger.e(`[ModuleContent] enterContentZoneWithRetries, unexpected rejection: ${err}`);
        this.isCurrentlyRetrying = false;
      });
    };
    tryOnce();
  }

  private async fetchContents(contentId: string | null, onFailure: (() => void) | null = null): Promise<void> {
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['method'] = 'queue';
    const dims: ScreenDimensionsDp = this.collectScreenDimensionsDp();
    const resolution: Record<string, Record<string, number>> = {
      'p': { 'w': dims.portraitWidth, 'h': dims.portraitHeight },
      'l': { 'w': dims.landscapeWidth, 'h': dims.landscapeHeight }
    };
    params['resolution'] = JSON.stringify(resolution);
    params['category'] = JSON.stringify(this.categories);
    params['la'] = this.detectLanguage();
    params['dt'] = this.detectDeviceType();
    if (contentId !== null) {
      params['content_id'] = contentId;
      params['preview'] = 'true';
    }
    const qs: string = Utils.buildQueryString(params);
    const usePost: boolean = this.config.network.shouldUsePost(qs);
    this.config.logger.i(`[ModuleContent] fetchContents start${contentId !== null ? ` content_id=${contentId}` : ''}`);
    try {
      const res = await this.config.network.execute(this.config.serverUrl, '/o/sdk/content', qs, usePost);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        this.config.logger.w(`[ModuleContent] fetchContents, http ${res.statusCode}`);
        if (onFailure !== null) onFailure();
        return;
      }
      const data: ContentData | null = this.parseResponse(res.body, dims.density);
      if (data === null) {
        const preview: string = res.body.length > 200 ? res.body.substring(0, 200) + '…' : res.body;
        this.config.logger.i(`[ModuleContent] fetchContents, no content in response (http ${res.statusCode}, body=${preview})`);
        return;
      }
      const pStr: string = data.portrait !== null
        ? `${data.portrait.width}x${data.portrait.height}@(${data.portrait.x},${data.portrait.y})`
        : 'none';
      const lStr: string = data.landscape !== null
        ? `${data.landscape.width}x${data.landscape.height}@(${data.landscape.x},${data.landscape.y})`
        : 'none';
      this.config.logger.i(`[ModuleContent] fetchContents, got content url=${data.html} portrait=${pStr} landscape=${lStr} — publishing`);
      this.showContent(data);
    } catch (err) {
      this.config.logger.w(`[ModuleContent] fetchContents, failed: ${err}`);
      if (onFailure !== null) onFailure();
    }
  }

  private showContent(data: ContentData): void {
    // Dev guide §Display Behavior: "Content overlay is not shown if a
    // feedback widget is currently being displayed."
    const feedbackShowing: boolean = this.feedbackShowingProvider !== null
      ? this.feedbackShowingProvider()
      : false;
    if (feedbackShowing) {
      this.config.logger.d('[ModuleContent] showContent, feedback widget is showing — skipped');
      return;
    }
    if (OverlayStore.isContentActive()) {
      this.config.logger.d('[ModuleContent] showContent, overlay already active — skipped');
      return;
    }
    // Dev guide §Origin Validation: content URLs must match the configured
    // allowlist (server URL always included). Defense-in-depth against a
    // compromised server returning a URL to attacker-controlled HTML.
    if (!this.isAllowedContentOrigin(data.html)) {
      this.config.logger.w(
        `[ModuleContent] showContent, content URL origin not in allowlist — rejected: ${data.html}`);
      return;
    }
    this.isInContentZone = true;
    this.shouldFetchContents = false;
    const immersive: boolean = displayOptionToImmersive(this.displayMode);
    OverlayStore.publishContent(data, immersive);
    // Window-level layout change so the overlay can actually paint into the
    // status/nav-bar region. Pure component-level `expandSafeArea` can't
    // escape the window's reserved strips.
    WindowImmersive.setContent(immersive, this.config.context, this.config.logger);
  }

  // -- Response parsing --

  private parseResponse(body: string, density: number): ContentData | null {
    let obj: Record<string, Object>;
    try {
      const parsed: Object = JSON.parse(body);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
      obj = parsed as Record<string, Object>;
    } catch (err) {
      this.config.logger.d(`[ModuleContent] parseResponse, unparseable body: ${err}`);
      return null;
    }
    const htmlRaw: Object | undefined = obj['html'];
    const geoRaw: Object | undefined = obj['geo'];
    if (typeof htmlRaw !== 'string' || htmlRaw.length === 0) return null;
    if (geoRaw === undefined || geoRaw === null || typeof geoRaw !== 'object' || Array.isArray(geoRaw)) return null;
    const geo: Record<string, Object> = geoRaw as Record<string, Object>;
    const portrait: ContentPlacement | null = ModuleContent.placementFromGeo(geo['p'], density);
    const landscape: ContentPlacement | null = ModuleContent.placementFromGeo(geo['l'], density);
    if (portrait === null && landscape === null) return null;
    return new ContentData(htmlRaw, portrait, landscape);
  }

  /**
   * Server returns `geo` values in DP (the same unit we reported via
   * `resolution`). ArkUI's layout primitives treat bare numbers as **vp**
   * (virtual pixels), which are effectively DP — so we pass the values
   * through unchanged. Multiplying by density here would double-upscale the
   * overlay and push it off-screen. The `density` parameter is kept so a
   * future switch to px-based layout (if we ever need it) remains a
   * one-liner, but it is currently unused.
   */
  private static placementFromGeo(raw: Object | undefined, _density: number): ContentPlacement | null {
    if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) return null;
    const obj: Record<string, Object> = raw as Record<string, Object>;
    const x: number = ModuleContent.numOr(obj['x'], 0);
    const y: number = ModuleContent.numOr(obj['y'], 0);
    const w: number = ModuleContent.numOr(obj['w'], 0);
    const h: number = ModuleContent.numOr(obj['h'], 0);
    if (w <= 0 || h <= 0) return null;
    return new ContentPlacement(Math.round(x), Math.round(y), Math.round(w), Math.round(h));
  }

  private static numOr(v: Object | undefined, fallback: number): number {
    if (v === undefined) return fallback;
    const n: number = Number(v);
    return Number.isFinite(n) ? n : fallback;
  }

  private static parseQueryParams(url: string): Record<string, string> {
    const out: Record<string, string> = {};
    const q: number = url.indexOf('?');
    if (q === -1) return out;
    let fragmentEnd: number = url.indexOf('#', q + 1);
    if (fragmentEnd === -1) fragmentEnd = url.length;
    const qs: string = url.substring(q + 1, fragmentEnd);
    if (qs.length === 0) return out;
    const parts: string[] = qs.split('&');
    for (let i = 0; i < parts.length; i++) {
      const kv: string = parts[i];
      if (kv.length === 0) continue;
      const eq: number = kv.indexOf('=');
      let k: string; let v: string;
      if (eq === -1) { k = kv; v = ''; }
      else { k = kv.substring(0, eq); v = kv.substring(eq + 1); }
      try { out[decodeURIComponent(k)] = decodeURIComponent(v); }
      catch (err) { out[k] = v; }
    }
    return out;
  }

  private static stripMarker(url: string, marker: string): string {
    let result: string = url;
    const patterns: string[] = [`&${marker}`, `?${marker}&`, `?${marker}`];
    for (let i = 0; i < patterns.length; i++) {
      const p: string = patterns[i];
      const idx: number = result.indexOf(p);
      if (idx !== -1) {
        if (p === `?${marker}&`) {
          result = result.substring(0, idx + 1) + result.substring(idx + p.length);
        } else {
          result = result.substring(0, idx) + result.substring(idx + p.length);
        }
        break;
      }
    }
    return result;
  }

  // -- Screen/device helpers --

  private collectScreenDimensionsDp(): ScreenDimensionsDp {
    let density: number = 2;
    let widthPx: number = 720;
    let heightPx: number = 1280;
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      widthPx = d.width;
      heightPx = d.height;
      density = d.densityPixels || (d.densityDPI / 160) || 1;
    } catch (err) {
      this.config.logger.d(`[ModuleContent] collectScreenDimensionsDp, display unavailable: ${err}`);
    }
    const widthDp: number = Math.floor(widthPx / density);
    const heightDp: number = Math.floor(heightPx / density);
    const isPortrait: boolean = heightPx >= widthPx;
    const portraitWidth: number = isPortrait ? widthDp : heightDp;
    const portraitHeight: number = isPortrait ? heightDp : widthDp;
    const landscapeWidth: number = isPortrait ? heightDp : widthDp;
    const landscapeHeight: number = isPortrait ? widthDp : heightDp;
    return new ScreenDimensionsDp(portraitWidth, portraitHeight, landscapeWidth, landscapeHeight, density);
  }

  private detectLanguage(): string {
    try {
      const loc: string = i18n.System.getSystemLocale();
      const dash: number = loc.indexOf('-');
      return (dash !== -1 ? loc.substring(0, dash) : loc).toLowerCase();
    } catch (err) { return 'en'; }
  }

  private detectDeviceType(): string {
    try {
      const t: string = deviceInfo.deviceType;
      if (t === 'tablet') return 'tablet';
      if (t === 'tv') return 'smarttv';
      if (t === 'pc') return 'desktop';
      return 'phone';
    } catch (err) { return 'phone'; }
  }
}
