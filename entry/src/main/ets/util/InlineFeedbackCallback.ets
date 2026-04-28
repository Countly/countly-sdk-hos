import { FeedbackCallback } from 'countly-sdk-hos';

/**
 * ArkTS bans untyped object literals, so a FeedbackCallback cannot be built
 * inline as `{ onFinished: ..., onClosed: ... }`. This class lets any callsite
 * compose one from two lambdas without repeating the boilerplate.
 */
export class InlineFeedbackCallback implements FeedbackCallback {
  private onFin: (error: string | null) => void;
  private onCls: () => void;

  constructor(onFin: (error: string | null) => void, onCls: () => void) {
    this.onFin = onFin;
    this.onCls = onCls;
  }

  onFinished(error: string | null): void { this.onFin(error); }
  onClosed(): void { this.onCls(); }
}
