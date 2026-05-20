import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { Utils } from '../Utils';
import { Logger } from '../Logger';
import { OverlayStore, displayOptionToImmersive } from '../OverlayStore';
import { WindowImmersive } from '../WindowImmersive';
import {
  ConsentChangeSource,
  CountlyFeature,
  CountlyFeedbackWidget,
  FeedbackCallback,
  FeedbackWidgetType,
  RetrieveFeedbackWidgetData,
  RetrieveFeedbackWidgets,
  SegmentationMap,
  WebViewDisplayOption
} from '../../types/Types';

const PLATFORM: string = 'h';

const EVENT_KEY_NPS: string = '[CLY]_nps';
const EVENT_KEY_SURVEY: string = '[CLY]_survey';
const EVENT_KEY_RATING: string = '[CLY]_star_rating';

const ACTION_BASE_URL: string = 'https://countly_action_event';
const EXTERNAL_LINK_MARKER: string = 'cly_x_int=1';

/**
 * State for the currently-showing feedback widget. Kept alongside the
 * module's other fields so the overlay callbacks (`handleFeedbackUrl`,
 * `onFeedbackClosedByUser`) can resolve back to the widget without a
 * store round-trip.
 */
class ShowingWidget {
  public widget: CountlyFeedbackWidget;
  public callback: FeedbackCallback | null;

  constructor(widget: CountlyFeedbackWidget, callback: FeedbackCallback | null) {
    this.widget = widget;
    this.callback = callback;
  }
}

/**
 * User Feedback module. Post-refactor architecture (matches ModuleContent):
 *
 *   1. Widget list / data / manual reports go through the existing /o/sdk
 *      and /o/surveys endpoints.
 *   2. `presentFeedbackWidget(widget, callback)` publishes state to
 *      `OverlayStore`; the exported `CountlyFeedbackOverlay` @Component
 *      reads it and mounts a Web component.
 *   3. The overlay calls back via `handleFeedbackUrl(url)` on load
 *      intercept, and `onFeedbackClosedByUser()` when the overlay dismisses.
 *
 * No FeedbackPresenter interface, the SDK owns rendering end-to-end.
 */
export class ModuleFeedback extends ModuleBase {
  private core: SdkCore;
  private displayMode: WebViewDisplayOption = WebViewDisplayOption.IMMERSIVE;
  private showing: ShowingWidget | null = null;

  private feedbackEventRecorder: ((eventKey: string, seg: SegmentationMap) => Promise<void>) | null = null;
  private externalUrlOpener: ((url: string) => void) | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.core = core;
    this.displayMode = config.feedbackDisplayMode;
  }

  public setFeedbackEventRecorder(fn: (eventKey: string, seg: SegmentationMap) => Promise<void>): void {
    this.feedbackEventRecorder = fn;
  }

  public setExternalUrlOpener(fn: ((url: string) => void) | null): void {
    this.externalUrlOpener = fn;
  }

  /** Called by ModuleContent to check whether to defer content overlay. */
  public isShowing(): boolean {
    return this.showing !== null;
  }

  // -- Public API --

  public async getAvailableFeedbackWidgets(callback: RetrieveFeedbackWidgets): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.FEEDBACK)) {
      this.config.logger.v('[ModuleFeedback] getAvailableFeedbackWidgets, no feedback consent');
      this.invokeRetrieveCallback(callback, [], 'no feedback consent');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleFeedback] getAvailableFeedbackWidgets, temporary device ID mode');
      this.invokeRetrieveCallback(callback, [], 'temporary device ID mode');
      return;
    }
    const params: Record<string, string> = this.core.requestBuilder.baseParams();
    params['method'] = 'feedback';
    const qs: string = Utils.buildQueryString(params);
    const usePost: boolean = this.config.network.shouldUsePost(qs);
    try {
      const res = await this.config.network.execute(this.config.serverUrl, '/o/sdk', qs, usePost);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        this.invokeRetrieveCallback(callback, [], `http ${res.statusCode}`);
        return;
      }
      const widgets: CountlyFeedbackWidget[] = ModuleFeedback.parseWidgetList(res.body, this.config.logger);
      this.invokeRetrieveCallback(callback, widgets, null);
    } catch (err) {
      this.config.logger.w(`[ModuleFeedback] getAvailableFeedbackWidgets, failed: ${err}`);
      this.invokeRetrieveCallback(callback, [], String(err));
    }
  }

  public async getFeedbackWidgetData(widget: CountlyFeedbackWidget | null, callback: RetrieveFeedbackWidgetData): Promise<void> {
    if (widget === null) {
      this.config.logger.w('[ModuleFeedback] getFeedbackWidgetData, null widget');
      this.invokeDataCallback(callback, null, 'widget is null');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.FEEDBACK)) {
      this.invokeDataCallback(callback, null, 'no feedback consent');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.invokeDataCallback(callback, null, 'temporary device ID mode');
      return;
    }
    const endpoint: string = `/o/surveys/${widget.type}/widget`;
    const params: Record<string, string> = {};
    params['widget_id'] = widget.widgetId;
    params['shown'] = '1';
    params['sdk_version'] = this.config.sdkVersion;
    params['sdk_name'] = this.config.sdkName;
    params['platform'] = PLATFORM;
    params['app_version'] = this.config.appVersion;
    const qs: string = Utils.buildQueryString(params);
    try {
      const res = await this.config.network.execute(this.config.serverUrl, endpoint, qs, false);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        this.invokeDataCallback(callback, null, `http ${res.statusCode}`);
        return;
      }
      let parsed: Record<string, Object> | null = null;
      try {
        const o: Object = JSON.parse(res.body);
        if (o !== null && typeof o === 'object' && !Array.isArray(o)) {
          parsed = o as Record<string, Object>;
        }
      } catch (err) {
        this.invokeDataCallback(callback, null, `unparseable widget data: ${err}`);
        return;
      }
      this.invokeDataCallback(callback, parsed, null);
    } catch (err) {
      this.config.logger.w(`[ModuleFeedback] getFeedbackWidgetData, failed: ${err}`);
      this.invokeDataCallback(callback, null, String(err));
    }
  }

  public async presentFeedbackWidget(widget: CountlyFeedbackWidget | null, callback: FeedbackCallback | null): Promise<void> {
    if (widget === null) { this.notifyFinished(callback, 'widget is null'); return; }
    if (!this.core.consentModule.hasConsent(CountlyFeature.FEEDBACK)) { this.notifyFinished(callback, 'no feedback consent'); return; }
    if (this.core.deviceIdModule.isTemporary()) { this.notifyFinished(callback, 'temporary device ID mode'); return; }
    if (this.showing !== null) { this.notifyFinished(callback, 'another feedback widget is already showing'); return; }

    const url: string = this.buildWidgetUrl(widget);
    this.showing = new ShowingWidget(widget, callback);
    const immersive: boolean = displayOptionToImmersive(this.displayMode);
    OverlayStore.publishFeedback(widget, url, immersive);
    WindowImmersive.setFeedback(immersive, this.config.context, this.config.logger);
    this.notifyFinished(callback, null);
  }

  public async reportFeedbackWidgetManually(
    widget: CountlyFeedbackWidget | null,
    widgetData: Record<string, Object> | null,
    widgetResult: Record<string, Object> | null
  ): Promise<void> {
    if (widget === null) {
      this.config.logger.w('[ModuleFeedback] reportFeedbackWidgetManually, null widget, dropped');
      return;
    }
    if (!this.core.consentModule.hasConsent(CountlyFeature.FEEDBACK)) {
      this.config.logger.v('[ModuleFeedback] reportFeedbackWidgetManually, no feedback consent, dropped');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleFeedback] reportFeedbackWidgetManually, temporary device ID mode, dropped');
      return;
    }
    const seg: SegmentationMap = {};
    seg['platform'] = PLATFORM;
    seg['app_version'] = this.config.appVersion;
    seg['widget_id'] = widget.widgetId;
    if (widgetResult === null) {
      seg['closed'] = '1';
    } else {
      this.applyWidgetResult(widget, widgetResult, seg);
    }
    const key: string = ModuleFeedback.eventKeyFor(widget.type);
    const recorder = this.feedbackEventRecorder;
    if (recorder === null) {
      this.config.logger.w('[ModuleFeedback] reportFeedbackWidgetManually, event recorder not wired');
      return;
    }
    await recorder(key, seg);
    if (widgetData !== null) {
      ModuleFeedback.validateWidgetData(widget, widgetData, this.config.logger);
    }
  }

  public async presentNPS(nameIDorTag: string | null, callback: FeedbackCallback | null): Promise<void> {
    await this.presentByType(FeedbackWidgetType.NPS, nameIDorTag, callback);
  }
  public async presentSurvey(nameIDorTag: string | null, callback: FeedbackCallback | null): Promise<void> {
    await this.presentByType(FeedbackWidgetType.SURVEY, nameIDorTag, callback);
  }
  public async presentRating(nameIDorTag: string | null, callback: FeedbackCallback | null): Promise<void> {
    await this.presentByType(FeedbackWidgetType.RATING, nameIDorTag, callback);
  }

  // -- Overlay callbacks --

  /**
   * Called from CountlyFeedbackOverlay.onLoadIntercept. Returns true if the
   * SDK handled the URL (close / action=link / cly_x_int=1) and the webview
   * should block navigation.
   */
  public handleFeedbackUrl(url: string): boolean {
    if (Utils.isNullOrEmpty(url)) return false;
    const isCommand: boolean = url.startsWith(ACTION_BASE_URL);
    const isExternalMarker: boolean = url.indexOf(EXTERNAL_LINK_MARKER) !== -1;
    if (!isCommand && !isExternalMarker) return false;

    const params: Record<string, string> = ModuleFeedback.parseQueryParams(url);

    if (isCommand && params['cly_widget_command'] === '1') {
      // Widget-owned close button (versioned widgets)
      this.closeOverlayFromProtocol();
      return true;
    }
    if (isCommand && params['cly_x_action_event'] === '1') {
      const action: string | undefined = params['action'];
      if (action === 'link') {
        const link: string | undefined = params['link'];
        if (link !== undefined && link.length > 0) this.openExternalUrl(link);
      } else {
        this.config.logger.w(`[ModuleFeedback] intercept, unknown action '${action}'`);
      }
      if (params['close'] === '1') this.closeOverlayFromProtocol();
      return true;
    }
    if (isExternalMarker) {
      const cleaned: string = ModuleFeedback.stripMarker(url, EXTERNAL_LINK_MARKER);
      this.openExternalUrl(cleaned);
      return true;
    }
    this.config.logger.w(`[ModuleFeedback] unrecognized countly command: ${url}`);
    return true;
  }

  /** Called by the overlay when the user dismisses via SDK-drawn close. */
  public onFeedbackClosedByUser(): void {
    this.closeOverlayFromProtocol();
  }

  public onFeedbackLoadTimedOut(): void {
    this.config.logger.w('[ModuleFeedback] widget load timed out, closing overlay');
    this.closeOverlayFromProtocol();
  }

  // -- Internals --

  private closeOverlayFromProtocol(): void {
    const cur = this.showing;
    if (cur === null) return;
    this.showing = null;
    // Record cancel event + hide overlay + notify developer callback.
    this.recordCancelEvent(cur.widget).catch((err: Object) => {
      this.config.logger.e(`[ModuleFeedback] cancel event record rejected: ${err}`);
    });
    OverlayStore.hideFeedback();
    WindowImmersive.setFeedback(false, this.config.context, this.config.logger);
    if (cur.callback !== null) {
      try { cur.callback.onClosed(); }
      catch (err) { this.config.logger.e(`[ModuleFeedback] onClosed threw: ${err}`); }
    }
  }

  /** See ModuleContent.openExternalUrl, identical two-tier lookup. */
  private openExternalUrl(url: string): void {
    const opener = this.externalUrlOpener;
    if (opener !== null) {
      try { opener(url); }
      catch (err) { this.config.logger.e(`[ModuleFeedback] externalUrlOpener threw: ${err}`); }
      return;
    }
    Utils.openExternalUrlViaContext(this.config.context, url, this.config.logger);
  }

  private async presentByType(type: FeedbackWidgetType, nameIDorTag: string | null, callback: FeedbackCallback | null): Promise<void> {
    if (!this.core.consentModule.hasConsent(CountlyFeature.FEEDBACK)) {
      this.notifyFinished(callback, 'no feedback consent');
      return;
    }
    const resolve = (widgets: CountlyFeedbackWidget[], error: string | null): void => {
      if (error !== null) { this.notifyFinished(callback, error); return; }
      const needle: string = nameIDorTag === null ? '' : nameIDorTag;
      const match: CountlyFeedbackWidget | null = ModuleFeedback.selectWidget(widgets, type, needle);
      if (match === null) {
        this.notifyFinished(callback, `no ${type} widget found${needle.length > 0 ? ` for '${needle}'` : ''}`);
        return;
      }
      this.presentFeedbackWidget(match, callback).catch((err: Object) => {
        this.config.logger.e(`[ModuleFeedback] presentByType rejected: ${err}`);
      });
    };
    await this.getAvailableFeedbackWidgets(resolve);
  }

  private static selectWidget(widgets: CountlyFeedbackWidget[], type: FeedbackWidgetType, needle: string): CountlyFeedbackWidget | null {
    let fallback: CountlyFeedbackWidget | null = null;
    for (let i = 0; i < widgets.length; i++) {
      const w: CountlyFeedbackWidget = widgets[i];
      if (w.type !== type) continue;
      if (needle.length === 0) { if (fallback === null) fallback = w; continue; }
      if (w.widgetId === needle || w.name === needle) return w;
      for (let j = 0; j < w.tags.length; j++) { if (w.tags[j] === needle) return w; }
    }
    return fallback;
  }

  private buildWidgetUrl(widget: CountlyFeedbackWidget): string {
    const endpoint: string = `/feedback/${widget.type}`;
    const params: Record<string, string> = {};
    params['widget_id'] = widget.widgetId;
    params['device_id'] = this.core.deviceIdModule.getId();
    params['app_key'] = this.config.appKey;
    params['sdk_version'] = this.config.sdkVersion;
    params['sdk_name'] = this.config.sdkName;
    params['app_version'] = this.config.appVersion;
    params['platform'] = PLATFORM;
    const custom: Record<string, number> = { 'tc': 1 };
    if (widget.widgetVersion !== null && widget.widgetVersion.length > 0) {
      custom['xb'] = 1;
      custom['rw'] = 1;
    }
    params['custom'] = JSON.stringify(custom);
    return `${this.config.serverUrl}${endpoint}?${Utils.buildQueryString(params)}`;
  }

  private async recordCancelEvent(widget: CountlyFeedbackWidget): Promise<void> {
    const seg: SegmentationMap = {};
    seg['platform'] = PLATFORM;
    seg['app_version'] = this.config.appVersion;
    seg['widget_id'] = widget.widgetId;
    seg['closed'] = '1';
    const key: string = ModuleFeedback.eventKeyFor(widget.type);
    const recorder = this.feedbackEventRecorder;
    if (recorder === null) return;
    await recorder(key, seg);
  }

  private applyWidgetResult(widget: CountlyFeedbackWidget, result: Record<string, Object>, seg: SegmentationMap): void {
    const keys: string[] = Object.keys(result);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (k === null || k === undefined || k.length === 0) continue;
      const v: Object | null | undefined = result[k];
      if (v === null || v === undefined) continue;
      if (typeof v === 'string') {
        seg[k] = Utils.truncate(v, this.config.limits.maxValueSize);
      } else if (typeof v === 'number' || typeof v === 'boolean') {
        seg[k] = v as (string | number | boolean);
      } else if (Array.isArray(v)) {
        if (Utils.isSupportedSegmentationValue(v as (string[] | number[] | boolean[]))) {
          seg[k] = v as (string[] | number[] | boolean[]);
        }
      }
    }
    if (widget.type === FeedbackWidgetType.NPS) {
      const rating: Object | undefined = result['rating'];
      if (rating === undefined) this.config.logger.w('[ModuleFeedback] NPS result missing rating field');
      else {
        const n: number = Number(rating);
        if (!Number.isFinite(n) || n < 0 || n > 10) this.config.logger.w(`[ModuleFeedback] NPS rating out of [0,10]: ${n}`);
      }
    } else if (widget.type === FeedbackWidgetType.RATING) {
      const rating: Object | undefined = result['rating'];
      if (rating === undefined) this.config.logger.w('[ModuleFeedback] Rating result missing rating field');
      else {
        const n: number = Number(rating);
        if (!Number.isFinite(n) || n < 1 || n > 5) this.config.logger.w(`[ModuleFeedback] Rating rating out of [1,5]: ${n}`);
      }
    }
  }

  private static validateWidgetData(widget: CountlyFeedbackWidget, data: Record<string, Object>, logger: Logger): void {
    const id: Object | undefined = data['_id'];
    if (typeof id === 'string' && id !== widget.widgetId) {
      logger.w(`[ModuleFeedback] widget data _id '${id}' does not match widget.widgetId '${widget.widgetId}'`);
    }
    const t: Object | undefined = data['type'];
    if (typeof t === 'string' && t !== widget.type) {
      logger.w(`[ModuleFeedback] widget data type '${t}' does not match widget.type '${widget.type}'`);
    }
  }

  private static eventKeyFor(type: FeedbackWidgetType): string {
    switch (type) {
      case FeedbackWidgetType.NPS: return EVENT_KEY_NPS;
      case FeedbackWidgetType.SURVEY: return EVENT_KEY_SURVEY;
      case FeedbackWidgetType.RATING: return EVENT_KEY_RATING;
      default: return '';
    }
  }

  private static parseWidgetList(body: string, logger: Logger): CountlyFeedbackWidget[] {
    const out: CountlyFeedbackWidget[] = [];
    let parsed: Object;
    try { parsed = JSON.parse(body); }
    catch (err) { logger.e(`[ModuleFeedback] parseWidgetList, unparseable: ${err}`); return out; }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return out;
    const obj: Record<string, Object> = parsed as Record<string, Object>;
    const rawArr: Object | undefined = obj['result'];
    if (rawArr === undefined || !Array.isArray(rawArr)) {
      logger.w('[ModuleFeedback] parseWidgetList, response missing "result" array');
      return out;
    }
    const arr: Object[] = rawArr as Object[];
    for (let i = 0; i < arr.length; i++) {
      const entry: Object = arr[i];
      if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) continue;
      const item: Record<string, Object> = entry as Record<string, Object>;
      const idRaw: Object | undefined = item['_id'];
      const typeRaw: Object | undefined = item['type'];
      if (typeof idRaw !== 'string' || idRaw.length === 0) continue;
      if (typeof typeRaw !== 'string' || typeRaw.length === 0) continue;
      let type: FeedbackWidgetType;
      if (typeRaw === FeedbackWidgetType.NPS) type = FeedbackWidgetType.NPS;
      else if (typeRaw === FeedbackWidgetType.SURVEY) type = FeedbackWidgetType.SURVEY;
      else if (typeRaw === FeedbackWidgetType.RATING) type = FeedbackWidgetType.RATING;
      else { logger.w(`[ModuleFeedback] parseWidgetList, unknown type '${typeRaw}', dropped`); continue; }
      const nameRaw: Object | undefined = item['name'];
      const name: string = typeof nameRaw === 'string' ? nameRaw : '';
      const tagsRaw: Object | undefined = item['tg'];
      const tags: string[] = [];
      if (Array.isArray(tagsRaw)) {
        const tArr: Object[] = tagsRaw as Object[];
        for (let j = 0; j < tArr.length; j++) {
          const tv: Object = tArr[j];
          if (typeof tv === 'string') tags.push(tv);
        }
      }
      const wvRaw: Object | undefined = item['wv'];
      const wv: string | null = typeof wvRaw === 'string' && wvRaw.length > 0 ? wvRaw : null;
      out.push(new CountlyFeedbackWidget(idRaw, type, name, tags, wv));
    }
    return out;
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
        if (p === `?${marker}&`) result = result.substring(0, idx + 1) + result.substring(idx + p.length);
        else result = result.substring(0, idx) + result.substring(idx + p.length);
        break;
      }
    }
    return result;
  }

  private invokeRetrieveCallback(callback: RetrieveFeedbackWidgets, widgets: CountlyFeedbackWidget[], error: string | null): void {
    try { callback(widgets, error); }
    catch (err) { this.config.logger.e(`[ModuleFeedback] retrieve callback threw: ${err}`); }
  }

  private invokeDataCallback(callback: RetrieveFeedbackWidgetData, data: Record<string, Object> | null, error: string | null): void {
    try { callback(data, error); }
    catch (err) { this.config.logger.e(`[ModuleFeedback] data callback threw: ${err}`); }
  }

  private notifyFinished(callback: FeedbackCallback | null, error: string | null): void {
    if (callback === null) return;
    try { callback.onFinished(error); }
    catch (err) { this.config.logger.e(`[ModuleFeedback] onFinished threw: ${err}`); }
  }

  // -- Lifecycle --

  public override async onConsentChanged(_added: string[], removed: string[], _source: ConsentChangeSource): Promise<void> {
    if (removed.indexOf(CountlyFeature.FEEDBACK) !== -1 && this.showing !== null) {
      this.showing = null;
      OverlayStore.hideFeedback();
      WindowImmersive.setFeedback(false, this.config.context, this.config.logger);
    }
  }

  public override async onDeviceIdChangedNotMerged(_oldId: string, _newId: string): Promise<void> {
    if (this.showing !== null) {
      this.showing = null;
      OverlayStore.hideFeedback();
      WindowImmersive.setFeedback(false, this.config.context, this.config.logger);
    }
  }

  public override async onHalt(): Promise<void> {
    if (this.showing !== null) {
      this.showing = null;
      OverlayStore.hideFeedback();
      WindowImmersive.setFeedback(false, this.config.context, this.config.logger);
    }
  }
}
