import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { Logger } from './Logger';

/**
 * Window-level immersive layout controller.
 *
 * In HarmonyOS Stage Model, a component's `expandSafeArea` modifier only
 * enlarges its paint region within whatever layout space the *window*
 * already gave up. A default window reserves top/bottom strips for the
 * system bars, so no child — no matter how eagerly it expands — can be
 * drawn into those strips without a window-level toggle.
 *
 * `setWindowLayoutFullScreen(true)` releases those reservations. Combined
 * with `expandSafeArea([SYSTEM, CUTOUT])` on the overlay container, the
 * overlay renders edge-to-edge, while the app's other UI (whose root
 * doesn't opt into `expandSafeArea`) remains framework-padded — exactly
 * the IMMERSIVE contract from the dev guide.
 *
 * Reference-counted across the two overlay types. Both flags must be
 * false for the window to revert, so a content overlay dismissing while a
 * feedback widget is still visible doesn't collapse the layout under
 * feedback's feet.
 */
export class WindowImmersive {
  private static contentFS: boolean = false;
  private static feedbackFS: boolean = false;

  public static setContent(active: boolean, ctx: common.Context | null, logger: Logger): void {
    if (WindowImmersive.contentFS === active) return;
    WindowImmersive.contentFS = active;
    WindowImmersive.apply(ctx, logger);
  }

  public static setFeedback(active: boolean, ctx: common.Context | null, logger: Logger): void {
    if (WindowImmersive.feedbackFS === active) return;
    WindowImmersive.feedbackFS = active;
    WindowImmersive.apply(ctx, logger);
  }

  /** Halt / re-init safety: force both flags off and revert the window. */
  public static reset(ctx: common.Context | null, logger: Logger): void {
    WindowImmersive.contentFS = false;
    WindowImmersive.feedbackFS = false;
    WindowImmersive.apply(ctx, logger);
  }

  private static apply(ctx: common.Context | null, logger: Logger): void {
    if (ctx === null) {
      logger.d('[WindowImmersive] apply: no context — skipping window update');
      return;
    }
    const fullscreen: boolean = WindowImmersive.contentFS || WindowImmersive.feedbackFS;
    try {
      const uiCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
      window.getLastWindow(uiCtx).then((win: window.Window): void => {
        win.setWindowLayoutFullScreen(fullscreen).catch((err: Object): void => {
          logger.w(`[WindowImmersive] setWindowLayoutFullScreen(${fullscreen}) failed: ${err}`);
        });
      }).catch((err: Object): void => {
        logger.w(`[WindowImmersive] getLastWindow failed: ${err}`);
      });
    } catch (err) {
      logger.w(`[WindowImmersive] context not UIAbilityContext: ${err}`);
    }
  }
}
