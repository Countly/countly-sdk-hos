import webview from '@ohos.web.webview';
import display from '@ohos.display';
import { Countly } from '../Countly';
import { CountlyInstance } from '../CountlyInstance';

/** Dev guide §Display Behavior: fail-close if page doesn't load in 60s. */
const PAGE_LOAD_TIMEOUT_MS: number = 60 * 1000;

/** Dev guide §Content Communication Protocol — resize debounce. */
const RESIZE_NOTIFY_DEBOUNCE_MS: number = 200;

/**
 * SDK-rendered content overlay. The integrator mounts this once via
 * `CountlyOverlayRoot` and the SDK drives its visibility via AppStorage.
 *
 * Responsibilities:
 *   1. Re-render on OverlayStore publish / resize / close via @StorageLink.
 *   2. Mount a transparent `Web` component with the content URL.
 *      Start hidden + non-interactive; reveal once `onPageEnd` (the DOM
 *      `window.load` event) fires — dev guide §5522.
 *   3. Route every URL navigation through the SDK's content URL protocol
 *      handler so the content HTML owns its own chrome (close button, etc).
 *   4. Re-read orientation on rotation and notify the content HTML via
 *      `window.postMessage({type:"resize",...})`, debounced 200ms — dev
 *      guide §2418.
 *   5. Apply IMMERSIVE vs SAFE_AREA layout. `expandSafeArea` pairs with
 *      window-level `setWindowLayoutFullScreen(true)` from WindowImmersive.
 *   6. Enforce the 60s page-load timeout AND fail-close on main-frame,
 *      SSL, and critical sub-resource (js/css/image) load errors — dev
 *      guide §5541.
 */
@Component
export struct CountlyContentOverlay {
  /** Re-render trigger for every OverlayStore state change. */
  @StorageLink('cly_content_overlay_rev') contentRev: number = 0;
  @StorageLink('cly_content_overlay_active') contentActive: boolean = false;
  /** Watched: new URL resets the "ready" flag so the next page waits for load. */
  @StorageLink('cly_content_overlay_url') @Watch('onUrlChanged') contentUrl: string = '';
  @StorageProp('cly_content_overlay_p_x') pX: number = 0;
  @StorageProp('cly_content_overlay_p_y') pY: number = 0;
  @StorageProp('cly_content_overlay_p_w') pW: number = 0;
  @StorageProp('cly_content_overlay_p_h') pH: number = 0;
  @StorageProp('cly_content_overlay_l_x') lX: number = 0;
  @StorageProp('cly_content_overlay_l_y') lY: number = 0;
  @StorageProp('cly_content_overlay_l_w') lW: number = 0;
  @StorageProp('cly_content_overlay_l_h') lH: number = 0;
  @StorageProp('cly_content_overlay_immersive') immersive: number = 1;

  private webController: webview.WebviewController = new webview.WebviewController();
  // null = no timer scheduled (HMOS setTimeout may legitimately return 0).
  private loadTimer: number | null = null;
  @State hasTimedOut: boolean = false;
  /**
   * True once `onPageEnd` fires for the current URL. Controls the Web's
   * opacity + hit-test so the user doesn't see half-painted content and
   * can't interact with an incomplete widget — dev guide §5522.
   */
  @State pageLoaded: boolean = false;

  /** Bumped on every `display.on('change')` so build() re-reads orientation. */
  @State rotationTick: number = 0;
  /** Retained for clean `display.off` (same function ref required). */
  private displayChangeListener: ((id: number) => void) | null = null;
  /** Debounce handle for SDK→content resize postMessage notifications. */
  private resizeDebounceTimer: number | null = null;

  onUrlChanged(): void {
    this.pageLoaded = false;
  }

  aboutToAppear(): void {
    this.hasTimedOut = false;
    this.pageLoaded = false;
    try {
      this.displayChangeListener = (_id: number): void => {
        this.rotationTick = this.rotationTick + 1;
        this.scheduleResizeNotify();
      };
      display.on('change', this.displayChangeListener);
    } catch (_err) { /* rotation updates disabled on this platform */ }
  }

  aboutToDisappear(): void {
    this.cancelLoadTimer();
    if (this.resizeDebounceTimer !== null) {
      clearTimeout(this.resizeDebounceTimer);
      this.resizeDebounceTimer = null;
    }
    try {
      if (this.displayChangeListener !== null) {
        display.off('change', this.displayChangeListener);
        this.displayChangeListener = null;
      }
    } catch (_err) { /* noop */ }
  }

  /**
   * Returns true when the server response had no `geo` placement. IMMERSIVE
   * vs SAFE_AREA controls how the overlay meets system bars — it does NOT
   * force fullscreen; geo wins for sizing.
   */
  private isFullscreen(): boolean {
    return (this.pW <= 0 && this.pH <= 0) && (this.lW <= 0 && this.lH <= 0);
  }

  private isPortrait(): boolean {
    // Read rotationTick so ArkUI registers this method as dependent on it.
    // Without the read, build() wouldn't re-run on rotation.
    const _tick: number = this.rotationTick;
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return d.height >= d.width;
    } catch (_err) { return true; }
  }

  private currentX(): number { return this.isPortrait() ? this.pX : this.lX; }
  private currentY(): number { return this.isPortrait() ? this.pY : this.lY; }
  private currentW(): number {
    const p: boolean = this.isPortrait();
    const v: number = p ? this.pW : this.lW;
    return v > 0 ? v : (p ? this.lW : this.pW);
  }
  private currentH(): number {
    const p: boolean = this.isPortrait();
    const v: number = p ? this.pH : this.lH;
    return v > 0 ? v : (p ? this.lH : this.pH);
  }

  private interceptUrl(url: string): boolean {
    try {
      const c: CountlyInstance = Countly.sharedInstance();
      return c.handleContentOverlayUrl(url);
    } catch (_err) { return false; }
  }

  /**
   * Schedules a debounced `window.postMessage` call to the content so it
   * can reflow for the new viewport. Per dev guide §2429 — debounce ~200ms
   * to avoid flooding on rapid orientation changes.
   */
  private scheduleResizeNotify(): void {
    if (this.resizeDebounceTimer !== null) {
      clearTimeout(this.resizeDebounceTimer);
    }
    this.resizeDebounceTimer = setTimeout((): void => {
      this.resizeDebounceTimer = null;
      if (!this.contentActive || this.contentUrl.length === 0) return;
      try {
        const d: display.Display = display.getDefaultDisplaySync();
        const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
        const widthDp: number = Math.floor(d.width / density);
        const heightDp: number = Math.floor(d.height / density);
        // Wrap in try/catch inside the JS so a receiver throwing doesn't
        // surface as a runJavaScript rejection.
        const js: string =
          `try { window.postMessage({type:"resize",width:${widthDp},height:${heightDp}},"*"); } catch(e) {}`;
        this.webController.runJavaScript(js).catch((_err: Object): void => { /* noop */ });
      } catch (_err) { /* display unavailable */ }
    }, RESIZE_NOTIFY_DEBOUNCE_MS) as number;
  }

  /**
   * Page-load watchdog. Mirrors Android's 60s timeout. onPageEnd cancels
   * it — that event fires on the DOM `window.load` event, which itself
   * fires only after all sub-resources have loaded or failed.
   */
  private startLoadTimer(): void {
    this.cancelLoadTimer();
    this.hasTimedOut = false;
    this.loadTimer = setTimeout((): void => {
      if (this.hasTimedOut) return;
      this.hasTimedOut = true;
      try {
        const c: CountlyInstance = Countly.sharedInstance();
        c.onContentOverlayLoadTimedOut();
      } catch (_err) { /* noop */ }
    }, PAGE_LOAD_TIMEOUT_MS) as number;
  }

  private cancelLoadTimer(): void {
    if (this.loadTimer !== null) {
      clearTimeout(this.loadTimer);
      this.loadTimer = null;
    }
  }

  private onWebLoadFailed(): void {
    this.cancelLoadTimer();
    try {
      const c: CountlyInstance = Countly.sharedInstance();
      c.onContentOverlayLoadTimedOut();
    } catch (_err) { /* noop */ }
  }

  /**
   * Dev guide §5541: a failed *critical* sub-resource (js, css, or common
   * image format) should fail the overlay closed. Non-critical sub-resource
   * failures (e.g. a telemetry pixel) are ignored. This runs in addition
   * to the main-frame and SSL error paths.
   */
  private static isCriticalResource(url: string): boolean {
    let p: string = url;
    const q: number = p.indexOf('?'); if (q !== -1) p = p.substring(0, q);
    const h: number = p.indexOf('#'); if (h !== -1) p = p.substring(0, h);
    p = p.toLowerCase();
    return p.endsWith('.js') || p.endsWith('.css') || p.endsWith('.png')
      || p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.webp');
  }

  @Builder fullscreenContent() {
    Web({ src: this.contentUrl, controller: this.webController })
      .width('100%').height('100%')
      .backgroundColor(Color.Transparent)
      // Hidden + non-interactive until onPageEnd — dev guide §5522 ("WebView
      // should start as invisible and non-interactive").
      .opacity(this.pageLoaded ? 1 : 0)
      .hitTestBehavior(this.pageLoaded ? HitTestMode.Default : HitTestMode.None)
      .onControllerAttached(() => { this.startLoadTimer(); })
      .onPageEnd(() => {
        this.cancelLoadTimer();
        this.pageLoaded = true;
        this.scheduleResizeNotify();
      })
      .onLoadIntercept((event): boolean => {
        return this.interceptUrl(event.data.getRequestUrl());
      })
      .onErrorReceive((event): void => {
        const req = event.request;
        if (req === undefined || req === null) return;
        if (req.isMainFrame()) { this.onWebLoadFailed(); return; }
        try {
          if (CountlyContentOverlay.isCriticalResource(req.getRequestUrl())) {
            this.onWebLoadFailed();
          }
        } catch (_err) { /* noop */ }
      })
      .onSslErrorEventReceive((event): void => {
        event.handler.handleCancel();
        this.onWebLoadFailed();
      })
  }

  /**
   * Placed mode: position the Web at server-supplied (x, y, w, h) in vp.
   * Content overlays are self-closing: the HTML ships its own close button
   * wired to the `cly_x_action_event=1&close=1` URL protocol handled by
   * ModuleContent. No SDK chrome on top.
   */
  @Builder placedContent() {
    Web({ src: this.contentUrl, controller: this.webController })
      .position({ x: this.currentX(), y: this.currentY() })
      .width(this.currentW())
      .height(this.currentH())
      .backgroundColor(Color.Transparent)
      .opacity(this.pageLoaded ? 1 : 0)
      .hitTestBehavior(this.pageLoaded ? HitTestMode.Default : HitTestMode.None)
      .onControllerAttached(() => { this.startLoadTimer(); })
      .onPageEnd(() => {
        this.cancelLoadTimer();
        this.pageLoaded = true;
        this.scheduleResizeNotify();
      })
      .onLoadIntercept((event): boolean => {
        return this.interceptUrl(event.data.getRequestUrl());
      })
      .onErrorReceive((event): void => {
        const req = event.request;
        if (req === undefined || req === null) return;
        if (req.isMainFrame()) { this.onWebLoadFailed(); return; }
        try {
          if (CountlyContentOverlay.isCriticalResource(req.getRequestUrl())) {
            this.onWebLoadFailed();
          }
        } catch (_err) { /* noop */ }
      })
      .onSslErrorEventReceive((event): void => {
        event.handler.handleCancel();
        this.onWebLoadFailed();
      })
  }

  build() {
    if (this.contentActive && this.contentUrl.length > 0) {
      if (this.isFullscreen()) {
        if (this.immersive === 1) {
          Stack() {
            this.fullscreenContent()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
          .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT])
        } else {
          Stack() {
            this.fullscreenContent()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
        }
      } else {
        // Placed mode: non-overlay touches pass through to the underlying
        // app (dev guide: "underlying app must continue to work").
        if (this.immersive === 1) {
          Stack() {
            this.placedContent()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
          .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT])
        } else {
          Stack() {
            this.placedContent()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
        }
      }
    }
  }
}
