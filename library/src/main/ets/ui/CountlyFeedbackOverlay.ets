import webview from '@ohos.web.webview';
import { Countly } from '../Countly';
import { CountlyInstance } from '../CountlyInstance';

const PAGE_LOAD_TIMEOUT_MS: number = 60 * 1000;

/**
 * SDK-rendered feedback widget overlay. Mounted once via `CountlyOverlayRoot`
 * and driven entirely by AppStorage state published from ModuleFeedback.
 *
 * Versioned widgets (`widgetVersion` set, `xb=1` / `rw=1` in the custom
 * param) render fullscreen with the webview's own close button, dismissed
 * via URL intercept (`cly_widget_command=1&close=1`). Legacy widgets
 * render in a dialog frame with an SDK-drawn Close button (they predate
 * the URL protocol).
 *
 * Follows the same load-visibility discipline as the content overlay:
 * start with `opacity(0) + hitTestBehavior(None)` and reveal after
 * `onPageEnd`, so the user never sees a half-painted widget and can
 * continue to use the underlying app while it loads, dev guide §5522.
 */
@Component
export struct CountlyFeedbackOverlay {
  @StorageLink('cly_feedback_overlay_rev') feedbackRev: number = 0;
  @StorageLink('cly_feedback_overlay_active') feedbackActive: boolean = false;
  @StorageLink('cly_feedback_overlay_url') @Watch('onUrlChanged') feedbackUrl: string = '';
  @StorageProp('cly_feedback_overlay_type') feedbackType: string = '';
  @StorageProp('cly_feedback_overlay_versioned') versioned: number = 0;
  @StorageProp('cly_feedback_overlay_immersive') immersive: number = 1;

  private webController: webview.WebviewController = new webview.WebviewController();
  // null = no timer scheduled (HMOS setTimeout may legitimately return 0).
  private loadTimer: number | null = null;
  @State hasTimedOut: boolean = false;
  @State pageLoaded: boolean = false;

  onUrlChanged(): void {
    this.pageLoaded = false;
  }

  aboutToAppear(): void {
    this.hasTimedOut = false;
    this.pageLoaded = false;
  }

  aboutToDisappear(): void {
    this.cancelLoadTimer();
  }

  private interceptUrl(url: string): boolean {
    try {
      const c: CountlyInstance = Countly.sharedInstance();
      return c.handleFeedbackOverlayUrl(url);
    } catch (_err) { return false; }
  }

  /** Close button handler for the legacy dialog Close button. */
  private dismissOverlay(): void {
    this.cancelLoadTimer();
    try { Countly.sharedInstance().onFeedbackOverlayClosed(); }
    catch (_err) { /* noop */ }
  }

  private startLoadTimer(): void {
    this.cancelLoadTimer();
    this.hasTimedOut = false;
    this.loadTimer = setTimeout((): void => {
      if (this.hasTimedOut) return;
      this.hasTimedOut = true;
      try { Countly.sharedInstance().onFeedbackOverlayLoadTimedOut(); }
      catch (_err) { /* noop */ }
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
    try { Countly.sharedInstance().onFeedbackOverlayLoadTimedOut(); }
    catch (_err) { /* noop */ }
  }

  /** Critical-resource matcher, mirrors CountlyContentOverlay. */
  private static isCriticalResource(url: string): boolean {
    let p: string = url;
    const q: number = p.indexOf('?'); if (q !== -1) p = p.substring(0, q);
    const h: number = p.indexOf('#'); if (h !== -1) p = p.substring(0, h);
    p = p.toLowerCase();
    return p.endsWith('.js') || p.endsWith('.css') || p.endsWith('.png')
      || p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.webp');
  }

  @Builder fullscreenWidget() {
    // Versioned widgets, no SDK chrome, close comes from webview's own UI
    // via URL intercept (cly_widget_command=1).
    Web({ src: this.feedbackUrl, controller: this.webController })
      .width('100%').height('100%')
      .backgroundColor(Color.Transparent)
      .opacity(this.pageLoaded ? 1 : 0)
      .hitTestBehavior(this.pageLoaded ? HitTestMode.Default : HitTestMode.None)
      .onControllerAttached(() => { this.startLoadTimer(); })
      .onPageEnd(() => {
        this.cancelLoadTimer();
        this.pageLoaded = true;
      })
      .onLoadIntercept((event): boolean => {
        return this.interceptUrl(event.data.getRequestUrl());
      })
      .onErrorReceive((event): void => {
        const req = event.request;
        if (req === undefined || req === null) return;
        if (req.isMainFrame()) { this.onWebLoadFailed(); return; }
        try {
          if (CountlyFeedbackOverlay.isCriticalResource(req.getRequestUrl())) {
            this.onWebLoadFailed();
          }
        } catch (_err) { /* noop */ }
      })
      .onSslErrorEventReceive((event): void => {
        event.handler.handleCancel();
        this.onWebLoadFailed();
      })
  }

  @Builder dialogWidget() {
    Column() {
      Row() {
        Text(`Feedback (${this.feedbackType})`)
          .fontSize(15).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('Close')
          .fontSize(13).height(32)
          .onClick((): void => this.dismissOverlay())
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#FFFFFF')

      Web({ src: this.feedbackUrl, controller: this.webController })
        .layoutWeight(1).width('100%')
        .opacity(this.pageLoaded ? 1 : 0)
        .hitTestBehavior(this.pageLoaded ? HitTestMode.Default : HitTestMode.None)
        .onControllerAttached(() => { this.startLoadTimer(); })
        .onPageEnd(() => {
          this.cancelLoadTimer();
          this.pageLoaded = true;
        })
        .onLoadIntercept((event): boolean => {
          return this.interceptUrl(event.data.getRequestUrl());
        })
        .onErrorReceive((event): void => {
          const req = event.request;
          if (req === undefined || req === null) return;
          if (req.isMainFrame()) { this.onWebLoadFailed(); return; }
          try {
            if (CountlyFeedbackOverlay.isCriticalResource(req.getRequestUrl())) {
              this.onWebLoadFailed();
            }
          } catch (_err) { /* noop */ }
        })
        .onSslErrorEventReceive((event): void => {
          event.handler.handleCancel();
          this.onWebLoadFailed();
        })
    }
    .width('92%').height('72%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .shadow({ radius: 12, color: '#44000000', offsetX: 0, offsetY: 4 })
  }

  build() {
    if (this.feedbackActive && this.feedbackUrl.length > 0) {
      if (this.versioned === 1) {
        if (this.immersive === 1) {
          Stack() {
            this.fullscreenWidget()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
          .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT])
        } else {
          Stack() {
            this.fullscreenWidget()
          }
          .width('100%').height('100%')
          .backgroundColor(Color.Transparent)
        }
      } else {
        // Legacy dialog: centered with dimmed backdrop, the modal dim is
        // the whole point of dialog mode, so it stays opaque regardless of
        // IMMERSIVE/SAFE_AREA.
        Column() {
          this.dialogWidget()
        }
        .width('100%').height('100%')
        .backgroundColor('#88000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
  }
}
