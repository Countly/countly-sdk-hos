import { describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness } from './TestHelpers';
import { OverlayKeys } from '../../../main/ets/internal/OverlayStore';
import {
  CountlyFeedbackWidget,
  FeedbackCallback,
  FeedbackWidgetType
} from '../../../main/ets/types/Types';

class RecordingFeedbackCallback implements FeedbackCallback {
  public finishedErrors: (string | null)[] = [];
  public closedCount: number = 0;
  onFinished(error: string | null): void { this.finishedErrors.push(error); }
  onClosed(): void { this.closedCount++; }
}

const WIDGET_LIST_BODY: string = JSON.stringify({
  result: [
    { _id: 'w1', type: 'nps', name: 'NPS Widget 1', tg: ['general'], wv: null },
    { _id: 'w2', type: 'survey', name: 'Survey A', tg: ['onboarding', 'v2'] },
    { _id: 'w3', type: 'rating', name: 'Rating', tg: [], wv: '1' }
  ]
});

function resetStore(): void {
  AppStorage.SetOrCreate<boolean>(OverlayKeys.FEEDBACK_ACTIVE, false);
  AppStorage.SetOrCreate<string>(OverlayKeys.FEEDBACK_URL, '');
  AppStorage.SetOrCreate<number>(OverlayKeys.FEEDBACK_REV, 0);
}

export default function feedbackTest() {
  describe('FeedbackTest', () => {
    it('getAvailableFeedbackWidgets_noConsent_returnsError', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      let receivedError: string | null = null;
      let receivedCount: number = -1;
      await h.instance.getAvailableFeedbackWidgets((widgets: CountlyFeedbackWidget[], error: string | null) => {
        receivedCount = widgets.length;
        receivedError = error;
      });
      expect(receivedCount).assertEqual(0);
      expect(receivedError !== null).assertTrue();
    });

    it('getAvailableFeedbackWidgets_parsesListCorrectly', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = WIDGET_LIST_BODY;
      let widgets: CountlyFeedbackWidget[] = [];
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], _e: string | null) => {
        widgets = w;
      });
      expect(widgets.length).assertEqual(3);
      expect(widgets[0].widgetId).assertEqual('w1');
      expect(widgets[0].type).assertEqual(FeedbackWidgetType.NPS);
      expect(widgets[1].type).assertEqual(FeedbackWidgetType.SURVEY);
      expect(widgets[1].tags.length).assertEqual(2);
      expect(widgets[2].widgetVersion).assertEqual('1');
      const reqs = h.network.calls.filter((c) => c.endpoint === '/o/sdk');
      expect(reqs.length).assertEqual(1);
      expect(reqs[0].data.indexOf('method=feedback') !== -1).assertTrue();
    });

    it('getFeedbackWidgetData_sendsShownEquals1', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = '{"_id":"w1","type":"nps"}';
      const widget = new CountlyFeedbackWidget('w1', FeedbackWidgetType.NPS, 'n', [], null);
      let data: Record<string, Object> | null = null;
      await h.instance.getFeedbackWidgetData(widget, (d, _e) => { data = d; });
      expect(data !== null).assertTrue();
      const reqs = h.network.calls.filter((c) => c.endpoint === '/o/surveys/nps/widget');
      expect(reqs.length).assertEqual(1);
      expect(reqs[0].data.indexOf('shown=1') !== -1).assertTrue();
      expect(reqs[0].data.indexOf('widget_id=w1') !== -1).assertTrue();
      expect(reqs[0].usePost).assertFalse();
    });

    it('presentFeedbackWidget_publishesStateAndUrl', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('widget42', FeedbackWidgetType.SURVEY, 'S', ['t1'], null);
      const cb = new RecordingFeedbackCallback();
      await h.instance.presentFeedbackWidget(widget, cb);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertTrue();
      const url: string | undefined = AppStorage.Get<string>(OverlayKeys.FEEDBACK_URL);
      expect(url !== undefined && url.indexOf('/feedback/survey') !== -1).assertTrue();
      expect(url!.indexOf('widget_id=widget42') !== -1).assertTrue();
      expect(url!.indexOf('platform=h') !== -1).assertTrue();
      // Non-versioned → custom is {"tc":1}.
      expect(url!.indexOf(encodeURIComponent('{"tc":1}')) !== -1).assertTrue();
      expect(AppStorage.Get<number>(OverlayKeys.FEEDBACK_VERSIONED)).assertEqual(0);
      expect(cb.finishedErrors.length).assertEqual(1);
      expect(cb.finishedErrors[0]).assertEqual(null);
    });

    it('presentFeedbackWidget_versionedWidget_marksVersioned', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('wver', FeedbackWidgetType.RATING, 'R', [], '1');
      await h.instance.presentFeedbackWidget(widget, null);
      const url: string | undefined = AppStorage.Get<string>(OverlayKeys.FEEDBACK_URL);
      expect(url!.indexOf(encodeURIComponent('"xb":1')) !== -1).assertTrue();
      expect(url!.indexOf(encodeURIComponent('"rw":1')) !== -1).assertTrue();
      expect(AppStorage.Get<number>(OverlayKeys.FEEDBACK_VERSIONED)).assertEqual(1);
    });

    it('handleFeedbackOverlayUrl_closeCommand_recordsCancelAndHides', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('wnps', FeedbackWidgetType.NPS, 'NPS', [], '1');
      const cb = new RecordingFeedbackCallback();
      await h.instance.presentFeedbackWidget(widget, cb);
      const handled: boolean = h.instance.handleFeedbackOverlayUrl(
        'https://countly_action_event/?cly_widget_command=1&close=1'
      );
      expect(handled).assertTrue();
      await flushTick(80);
      // [CLY]_nps cancel event should be force-flushed.
      const eventCalls = h.network.calls.filter((c) => c.data.indexOf('%5BCLY%5D_nps') !== -1);
      expect(eventCalls.length >= 1).assertTrue();
      expect(eventCalls[0].data.indexOf(encodeURIComponent('"closed":"1"')) !== -1).assertTrue();
      expect(cb.closedCount).assertEqual(1);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertFalse();
    });

    it('handleFeedbackOverlayUrl_actionLink_opensExternal', 0, async () => {
      resetStore();
      let opened: string = '';
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.instance.setExternalUrlOpener((url: string) => { opened = url; });
      const widget = new CountlyFeedbackWidget('w', FeedbackWidgetType.NPS, 'N', [], '1');
      await h.instance.presentFeedbackWidget(widget, null);
      const handled: boolean = h.instance.handleFeedbackOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=link&link=https%3A%2F%2Fexample.com%2Fdocs&close=1'
      );
      expect(handled).assertTrue();
      expect(opened).assertEqual('https://example.com/docs');
      await flushTick(50);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertFalse();
    });

    it('handleFeedbackOverlayUrl_regularUrl_returnsFalse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('w', FeedbackWidgetType.NPS, 'N', [], null);
      await h.instance.presentFeedbackWidget(widget, null);
      const handled: boolean = h.instance.handleFeedbackOverlayUrl('https://example.com/normal-link');
      expect(handled).assertFalse();
    });

    it('reportFeedbackWidgetManually_nullResult_marksClosed', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('wsurv', FeedbackWidgetType.SURVEY, 'S', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, null);
      await flushTick(80);
      const eventCalls = h.network.calls.filter((c) => c.data.indexOf('%5BCLY%5D_survey') !== -1);
      expect(eventCalls.length >= 1).assertTrue();
      expect(eventCalls[0].data.indexOf(encodeURIComponent('"closed":"1"')) !== -1).assertTrue();
    });

    it('reportFeedbackWidgetManually_ratingResult_forceFlushes', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('wr', FeedbackWidgetType.RATING, 'R', [], null);
      const result: Record<string, Object> = { 'rating': 4, 'comment': 'Nice' };
      await h.instance.reportFeedbackWidgetManually(widget, null, result);
      await flushTick(100);
      const calls = h.network.calls.filter((c) => c.data.indexOf('%5BCLY%5D_star_rating') !== -1);
      expect(calls.length >= 1).assertTrue();
    });

    it('presentNPS_filtersByType_andMatchesByTag', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = WIDGET_LIST_BODY;
      await h.instance.presentNPS('general', null);
      await flushTick(50);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertTrue();
      expect(AppStorage.Get<string>(OverlayKeys.FEEDBACK_TYPE)).assertEqual('nps');
      expect(AppStorage.Get<string>(OverlayKeys.FEEDBACK_WIDGET_ID)).assertEqual('w1');
    });

    it('presentSurvey_noMatch_reportsError', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({ result: [] });
      const cb = new RecordingFeedbackCallback();
      await h.instance.presentSurvey('nonexistent', cb);
      await flushTick(50);
      expect(cb.finishedErrors.length).assertEqual(1);
      expect(cb.finishedErrors[0] !== null).assertTrue();
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertFalse();
    });

    it('consentRevoked_hidesFeedbackOverlay', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['feedback']);
      });
      const widget = new CountlyFeedbackWidget('w', FeedbackWidgetType.NPS, 'N', [], null);
      await h.instance.presentFeedbackWidget(widget, null);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertTrue();
      h.instance.removeConsent(['feedback']);
      await flushTick(30);
      expect(AppStorage.Get<boolean>(OverlayKeys.FEEDBACK_ACTIVE) === true).assertFalse();
    });

    // ---------- Ported from ModuleFeedbackTests.java ----------

    // parseFeedbackList_null — parsing an empty/null body returns an empty list (no error).
    it('parseWidgetList_emptyBody_returnsEmpty', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = '{}';
      let widgets: CountlyFeedbackWidget[] = [];
      let err: string | null = null;
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], e: string | null) => {
        widgets = w;
        err = e;
      });
      expect(widgets.length).assertEqual(0);
      expect(err).assertEqual(null);
    });

    // parseFeedbackList_oneGoodWithGarbage — entries with unknown types or missing _id/type are dropped.
    it('parseWidgetList_oneGoodWithGarbage', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({
        result: [
          { _id: 'asd', type: 'qwe', name: 'zxc', tg: [] },
          { _id: '5f97284635935cc338e78200', type: 'nps', name: 'fsdfsdf', tg: ['/'] },
          { g4id: 'asd1', t4type: '432', nagdfgme: 'zxct', tgm: ['/'] }
        ]
      });
      let widgets: CountlyFeedbackWidget[] = [];
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], _e: string | null) => {
        widgets = w;
      });
      expect(widgets.length).assertEqual(1);
      expect(widgets[0].type).assertEqual(FeedbackWidgetType.NPS);
      expect(widgets[0].name).assertEqual('fsdfsdf');
      expect(widgets[0].widgetId).assertEqual('5f97284635935cc338e78200');
      expect(widgets[0].tags.length).assertEqual(1);
      expect(widgets[0].tags[0]).assertEqual('/');
    });

    // parseFeedbackList — mixed survey/nps/rating all parse.
    it('parseWidgetList_mixedTypes', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({
        result: [
          { _id: '5f8c6f959627f99e8e7de746', type: 'survey', name: 'sdfsdfdsf', tg: ['/'] },
          { _id: '5f8c6fd81ac8659e8846acf4', type: 'nps', name: 'fdsfsd', tg: ['a', '0'] },
          { _id: '5f97284635935cc338e78200', type: 'nps', name: 'fsdfsdf', tg: [] },
          { _id: '614871419f030e44be07d82f', type: 'rating', name: 'ratingName1', tg: ['/'] }
        ]
      });
      let widgets: CountlyFeedbackWidget[] = [];
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], _e: string | null) => {
        widgets = w;
      });
      expect(widgets.length).assertEqual(4);
      expect(widgets[0].type).assertEqual(FeedbackWidgetType.SURVEY);
      expect(widgets[0].widgetId).assertEqual('5f8c6f959627f99e8e7de746');
      expect(widgets[1].type).assertEqual(FeedbackWidgetType.NPS);
      expect(widgets[1].tags.length).assertEqual(2);
      expect(widgets[2].type).assertEqual(FeedbackWidgetType.NPS);
      expect(widgets[2].tags.length).assertEqual(0);
      expect(widgets[3].type).assertEqual(FeedbackWidgetType.RATING);
      expect(widgets[3].name).assertEqual('ratingName1');
    });

    // parseFaultyFeedbackList — missing 'tg' → empty tags; missing 'name' → ''; missing '_id' → dropped.
    it('parseWidgetList_faulty_droppedOrDefaulted', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({
        result: [
          { _id: 'survID1', type: 'survey', name: 'surv1' },                    // no tg → []
          { _id: 'survID2', type: 'survey', tg: ['/'] },                         // no name → ''
          { type: 'survey', name: 'surv3', tg: ['/'] },                          // no _id → dropped
          { _id: 'npsID1', type: 'nps', name: 'nps1' },
          { _id: 'npsID2', type: 'nps', tg: [] },
          { type: 'nps', name: 'nps3', tg: [] },                                 // no _id → dropped
          { _id: 'ratingID1', type: 'rating', name: 'rating1' },
          { _id: 'ratingID2', type: 'rating', tg: ['/'] },
          { type: 'rating', name: 'rating3', tg: ['/'] }                         // no _id → dropped
        ]
      });
      let widgets: CountlyFeedbackWidget[] = [];
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], _e: string | null) => {
        widgets = w;
      });
      expect(widgets.length).assertEqual(6);
      expect(widgets[0].widgetId).assertEqual('survID1');
      expect(widgets[0].name).assertEqual('surv1');
      expect(widgets[0].tags.length).assertEqual(0);
      expect(widgets[1].widgetId).assertEqual('survID2');
      expect(widgets[1].name).assertEqual('');
      expect(widgets[2].widgetId).assertEqual('npsID1');
      expect(widgets[3].widgetId).assertEqual('npsID2');
      expect(widgets[3].name).assertEqual('');
      expect(widgets[4].widgetId).assertEqual('ratingID1');
      expect(widgets[5].widgetId).assertEqual('ratingID2');
      expect(widgets[5].name).assertEqual('');
    });

    // reportFeedbackWidgetManuallyNPSReported — NPS result records widget_id/rating/comment.
    it('reportFeedbackWidgetManually_npsReported', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, { 'rating': 4, 'comment': '123456' });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf(encodeURIComponent('"widget_id":"1234"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"rating":4')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"comment":"123456"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"platform":"h"')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallyRatingReported — rating result records extra email/contactMe.
    it('reportFeedbackWidgetManually_ratingReported', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.RATING, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, {
        'rating': 4, 'comment': '123456', 'email': '123456', 'contactMe': true
      });
      await flushTick(100);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_star_rating');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf(encodeURIComponent('"widget_id":"1234"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"rating":4')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"comment":"123456"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"email":"123456"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"contactMe":true')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallyNPSClosed — null result records closed=1.
    it('reportFeedbackWidgetManually_npsClosed', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, null);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"closed":"1"')) !== -1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"widget_id":"1234"')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallyRatingClosed — null result on rating records closed=1.
    it('reportFeedbackWidgetManually_ratingClosed', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.RATING, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, null);
      await flushTick(100);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_star_rating');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"closed":"1"')) !== -1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"widget_id":"1234"')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallySurveyClosed — null result on survey records closed=1.
    it('reportFeedbackWidgetManually_surveyClosed', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.SURVEY, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, null);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_survey');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"closed":"1"')) !== -1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"widget_id":"1234"')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallyNPSBadResult_2 — out-of-range NPS rating is warned but still shipped.
    // (HOS treats the server as source of truth; Android drops — ported as "still recorded with warning".)
    it('reportFeedbackWidgetManually_npsOutOfRangeRating_stillSent', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, { 'rating': 11 });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"rating":11')) !== -1).assertTrue();
    });

    // reportFeedbackWidgetManuallyRatingBadResult_2 — out-of-range rating rating is warned but still shipped.
    it('reportFeedbackWidgetManually_ratingOutOfRangeRating_stillSent', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.RATING, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, { 'rating': 6 });
      await flushTick(100);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_star_rating');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf(encodeURIComponent('"rating":6')) !== -1).assertTrue();
    });

    // internalLimit_reportFeedbackWidgetManuallySurvey — max value size applies to string segmentation values;
    // keys are NOT truncated (feedback widget event).
    it('reportFeedbackWidgetManually_survey_valuesTruncated_keysPreserved', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.instance.config.limits.maxValueSize = 2;
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.SURVEY, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, {
        'key1': 'value1', 'key2': 'value2', 'key3': 'value3'
      });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_survey');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf(encodeURIComponent('"key1":"va"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"key2":"va"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"key3":"va"')) !== -1).assertTrue();
    });

    // internalLimit_reportFeedbackWidgetManually_setMaxValueSize — values of all types:
    // strings truncate, numbers/booleans pass through, Object/Map entries are stripped.
    it('reportFeedbackWidgetManually_nps_maxValueSize_stripsUnsupported', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.instance.config.limits.maxValueSize = 2;
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, {
        'rating': 10,
        'comment': 'huhu',
        'extras': 'sure_go_on',
        'map': { 'k1': 'v1' },
        'omg': 1.5e300
      });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf(encodeURIComponent('"rating":10')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"comment":"hu"')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"extras":"su"')) !== -1).assertTrue();
      // Nested Object/Map must not leak through
      expect(body.indexOf('%22map%22') === -1).assertTrue();
    });

    // reportFeedbackWidgetManually_validateSupportedArrays — primitive arrays survive,
    // mixed Object[] arrays are stripped.
    it('reportFeedbackWidgetManually_supportedArrays', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, {
        'arr': [1, 2, 3],
        'arrB': [true, false, true],
        'arrS': ['a', 'b', 'c'],
        'arrMixed': ['1', 1, true],
        'rating': 10,
        'comment': 'huhu'
      });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf(encodeURIComponent('"arr":[1,2,3]')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"arrB":[true,false,true]')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"arrS":["a","b","c"]')) !== -1).assertTrue();
      // Mixed-type array is not a supported segmentation value and is dropped.
      expect(body.indexOf('arrMixed') === -1).assertTrue();
    });

    // reportFeedbackWidgetManually_unsupportedDataTypesSegmentation — Objects/plain maps are stripped.
    it('reportFeedbackWidgetManually_unsupportedTypes_dropped', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, {
        'a': {},
        'b': { 'nested': 1 },
        'rating': 10,
        'comment': 'huhu'
      });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      expect(body.indexOf('%22a%22') === -1).assertTrue();
      expect(body.indexOf('%22b%22') === -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"rating":10')) !== -1).assertTrue();
      expect(body.indexOf(encodeURIComponent('"comment":"huhu"')) !== -1).assertTrue();
    });

    // Temp-id mode blocks getAvailableFeedbackWidgets with no network call.
    it('getAvailableFeedbackWidgets_tempIdMode_blocked', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      await h.instance.enableTemporaryIdMode();
      const baseline: number = h.network.calls.length;
      let err: string | null = null;
      let widgets: CountlyFeedbackWidget[] = [{} as CountlyFeedbackWidget];
      await h.instance.getAvailableFeedbackWidgets((w: CountlyFeedbackWidget[], e: string | null) => {
        widgets = w;
        err = e;
      });
      expect(widgets.length).assertEqual(0);
      expect(err !== null).assertTrue();
      const sdkCalls = h.network.calls.slice(baseline).filter((c) => c.endpoint === '/o/sdk');
      expect(sdkCalls.length).assertEqual(0);
    });

    // Temp-id mode blocks reportFeedbackWidgetManually (no event recorded).
    it('reportFeedbackWidgetManually_tempIdMode_blocked', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      await h.instance.enableTemporaryIdMode();
      const widget = new CountlyFeedbackWidget('1234', FeedbackWidgetType.NPS, 'someName', [], null);
      await h.instance.reportFeedbackWidgetManually(widget, null, { 'rating': 4 });
      await flushTick(80);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_nps');
      expect(calls.length).assertEqual(0);
    });
  });
}
