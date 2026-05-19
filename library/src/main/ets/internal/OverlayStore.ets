import { ContentData, CountlyFeedbackWidget, WebViewDisplayOption } from '../types/Types';

/**
 * AppStorage keys used by the overlay system. Centralised so an integrator
 * accidentally reading one of these with a typo would be a compile-time
 * error (they're exported constants, not magic strings scattered through
 * modules + @Component structs).
 */
export class OverlayKeys {
  /**
   * Revision counter bumped on every content state publish. @StorageLink on
   * this triggers a component re-read of the rest of the state in a single
   * frame. Using a counter (vs a struct) avoids ArkUI's shallow-equality
   * dedup for identical-but-refreshed payloads.
   */
  public static readonly CONTENT_REV: string = 'cly_content_overlay_rev';
  /** True while content is being shown. False when closed / not displayed. */
  public static readonly CONTENT_ACTIVE: string = 'cly_content_overlay_active';
  /** Content URL to load in the Web component. */
  public static readonly CONTENT_URL: string = 'cly_content_overlay_url';
  /** Portrait placement, pixel values. "" = fullscreen / immersive. */
  public static readonly CONTENT_P_X: string = 'cly_content_overlay_p_x';
  public static readonly CONTENT_P_Y: string = 'cly_content_overlay_p_y';
  public static readonly CONTENT_P_W: string = 'cly_content_overlay_p_w';
  public static readonly CONTENT_P_H: string = 'cly_content_overlay_p_h';
  /** Landscape placement, pixel values. */
  public static readonly CONTENT_L_X: string = 'cly_content_overlay_l_x';
  public static readonly CONTENT_L_Y: string = 'cly_content_overlay_l_y';
  public static readonly CONTENT_L_W: string = 'cly_content_overlay_l_w';
  public static readonly CONTENT_L_H: string = 'cly_content_overlay_l_h';
  /** 1 = IMMERSIVE (no safe-area insets), 0 = SAFE_AREA. */
  public static readonly CONTENT_IMMERSIVE: string = 'cly_content_overlay_immersive';

  public static readonly FEEDBACK_REV: string = 'cly_feedback_overlay_rev';
  public static readonly FEEDBACK_ACTIVE: string = 'cly_feedback_overlay_active';
  public static readonly FEEDBACK_URL: string = 'cly_feedback_overlay_url';
  /** "nps" | "survey" | "rating", matches server wire format. */
  public static readonly FEEDBACK_TYPE: string = 'cly_feedback_overlay_type';
  /** Widget id, read by SDK on close to record the cancel event. */
  public static readonly FEEDBACK_WIDGET_ID: string = 'cly_feedback_overlay_widget_id';
  /**
   * 1 if the widget has a `wv` value (versioned). Versioned widgets render
   * fullscreen with the webview's own close button; legacy widgets render
   * as a dialog with an SDK-drawn close button.
   */
  public static readonly FEEDBACK_VERSIONED: string = 'cly_feedback_overlay_versioned';
  public static readonly FEEDBACK_IMMERSIVE: string = 'cly_feedback_overlay_immersive';
}

/**
 * AppStorage bridge between SDK modules and the exported overlay components.
 *
 * Why AppStorage and not a singleton class: ArkUI components require
 * observable state to trigger re-render. @StorageLink on an AppStorage key
 * is the natural cross-module reactivity primitive, a plain shared class
 * would need a manual notification mechanism the component subscribes to,
 * which duplicates what AppStorage already does.
 *
 * Why only primitives: @StorageLink tracks reference equality well for
 * primitives (boolean, number, string) but has surprising behaviour for
 * mutable objects. Decomposing the state into primitive fields keyed by
 * `OverlayKeys.*` is verbose but predictable.
 *
 * Only the shared Countly instance drives these, multi-instance mode does
 * not multiplex onto a single process-wide overlay.
 */
export class OverlayStore {
  // -- Content --

  public static publishContent(data: ContentData, immersive: boolean): void {
    AppStorage.SetOrCreate<string>(OverlayKeys.CONTENT_URL, data.html);
    if (data.portrait !== null) {
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_X, data.portrait.x);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_Y, data.portrait.y);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_W, data.portrait.width);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_H, data.portrait.height);
    } else {
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_W, 0);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_H, 0);
    }
    if (data.landscape !== null) {
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_X, data.landscape.x);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_Y, data.landscape.y);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_W, data.landscape.width);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_H, data.landscape.height);
    } else {
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_W, 0);
      AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_H, 0);
    }
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_IMMERSIVE, immersive ? 1 : 0);
    AppStorage.SetOrCreate<boolean>(OverlayKeys.CONTENT_ACTIVE, true);
    // Revision bump must be last so any observer that reacts to REV sees a
    // fully-populated state snapshot.
    OverlayStore.bumpContentRev();
  }

  public static hideContent(): void {
    AppStorage.SetOrCreate<boolean>(OverlayKeys.CONTENT_ACTIVE, false);
    AppStorage.SetOrCreate<string>(OverlayKeys.CONTENT_URL, '');
    OverlayStore.bumpContentRev();
  }

  public static isContentActive(): boolean {
    const v: boolean | undefined = AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE);
    return v === true;
  }

  /**
   * Update just the placement (content triggered a `resize_me` message). Does
   * not bump ACTIVE, the overlay is already showing.
   */
  public static resizeContent(px: number, py: number, pw: number, ph: number, lx: number, ly: number, lw: number, lh: number): void {
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_X, px);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_Y, py);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_W, pw);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_P_H, ph);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_X, lx);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_Y, ly);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_W, lw);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_L_H, lh);
    OverlayStore.bumpContentRev();
  }

  private static bumpContentRev(): void {
    const cur: number | undefined = AppStorage.Get<number>(OverlayKeys.CONTENT_REV);
    AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_REV, (cur ?? 0) + 1);
  }

  // -- Feedback --

  public static publishFeedback(widget: CountlyFeedbackWidget, url: string, immersive: boolean): void {
    AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_URL, url);
    AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_TYPE, widget.type);
    AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_WIDGET_ID, widget.widgetId);
    const versioned: boolean = widget.widgetVersion !== null && widget.widgetVersion.length > 0;
    AppStorage.SetOrCreate<number>(OverlayKeys.FEEDBACK_VERSIONED, versioned ? 1 : 0);
    AppStorage.SetOrCreate<number>(OverlayKeys.FEEDBACK_IMMERSIVE, immersive ? 1 : 0);
    AppStorage.SetOrCreate<boolean>(OverlayKeys.FEEDBACK_ACTIVE, true);
    OverlayStore.bumpFeedbackRev();
  }

  public static hideFeedback(): void {
    AppStorage.SetOrCreate<boolean>(OverlayKeys.FEEDBACK_ACTIVE, false);
    AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_URL, '');
    OverlayStore.bumpFeedbackRev();
  }

  public static isFeedbackActive(): boolean {
    const v: boolean | undefined = AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE);
    return v === true;
  }

  private static bumpFeedbackRev(): void {
    const cur: number | undefined = AppStorage.Get<number>(OverlayKeys.FEEDBACK_REV);
    AppStorage.SetOrCreate<number>(OverlayKeys.FEEDBACK_REV, (cur ?? 0) + 1);
  }

  /**
   * Reset every overlay key, used on halt so a re-init doesn't see stale
   * state from the previous instance.
   */
  public static clearAll(): void {
    AppStorage.SetOrCreate<boolean>(OverlayKeys.CONTENT_ACTIVE, false);
    AppStorage.SetOrCreate<boolean>(OverlayKeys.FEEDBACK_ACTIVE, false);
    AppStorage.SetOrCreate<string>(OverlayKeys.CONTENT_URL, '');
    AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_URL, '');
    OverlayStore.bumpContentRev();
    OverlayStore.bumpFeedbackRev();
  }
}

/**
 * Immersive vs safe-area translation helper. Called at publish time so the
 * component never has to know about the enum, it just reads a boolean.
 */
export function displayOptionToImmersive(opt: WebViewDisplayOption): boolean {
  return opt === WebViewDisplayOption.IMMERSIVE;
}
