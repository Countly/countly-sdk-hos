import { CountlyContentOverlay } from './CountlyContentOverlay';
import { CountlyFeedbackOverlay } from './CountlyFeedbackOverlay';

/**
 * The single mount point the integrator adds to their UI tree (usually at
 * the top-level @Component / shared page frame) to enable SDK-rendered
 * Content Zone + User Feedback overlays.
 *
 * Typical wiring:
 *
 *   build() {
 *     Stack() {
 *       // app content
 *       CountlyOverlayRoot()
 *     }
 *   }
 *
 * The component renders nothing when no overlay is active. When
 * ModuleContent or ModuleFeedback publish state to the OverlayStore, the
 * inner components re-render automatically via @StorageLink. Feedback is
 * stacked *after* content so if both happen to be active (e.g. a race
 * during a device-id change) feedback visually wins, matching the dev
 * guide's "content overlay is not shown if a feedback widget is currently
 * being displayed" rule at the UI level as a belt-and-braces backup to
 * ModuleContent's `feedbackShowingProvider` check.
 */
@Component
export struct CountlyOverlayRoot {
  build() {
    Stack() {
      CountlyContentOverlay()
      CountlyFeedbackOverlay()
    }
    .width('100%').height('100%')
    // Transparent: when no overlay is active, this Stack is empty and must
    // not capture touches from the underlying app.
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
