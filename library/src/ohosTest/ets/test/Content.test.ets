import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses } from './TestHelpers';
import { OverlayKeys } from '../../../main/ets/internal/OverlayStore';
import { ContentStatus } from '../../../main/ets/types/Types';

/**
 * Content Zone tests, post-refactor the overlay is rendered by the SDK via
 * AppStorage state, not an injected presenter. Tests assert on AppStorage
 * content + SDK callback behaviour (URL intercept dispatch, close handling).
 */

// Content URL uses the harness server host so it passes origin validation
// (the server URL is always in the allowlist, dev guide §Origin Validation).
// Tests that need to verify off-host rejection add their own body with a
// foreign origin and an explicit assertion.
const VALID_BODY: string = JSON.stringify({
  html: 'https://try.count.ly/content',
  geo: {
    p: { x: 0, y: 0, w: 360, h: 640 },
    l: { x: 0, y: 0, w: 640, h: 360 }
  }
});

function resetStore(): void {
  AppStorage.SetOrCreate<boolean>(OverlayKeys.CONTENT_ACTIVE, false);
  AppStorage.SetOrCreate<string>(OverlayKeys.CONTENT_URL, '');
  AppStorage.SetOrCreate<number>(OverlayKeys.CONTENT_REV, 0);
}

export default function contentTest() {
  describe('ContentTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('enterContentZone_noConsent_omitsFetch', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      await h.instance.enterContentZone();
      await flushTick(30);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length).assertEqual(0);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('enterContentZone_withConsent_sendsFetchRequest', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf('method=queue') !== -1).assertTrue();
      expect(calls[0].data.indexOf('resolution=') !== -1).assertTrue();
    });

    it('enterContentZone_publishesStateToAppStorage', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      expect(AppStorage.Get<string>(OverlayKeys.CONTENT_URL)).assertEqual('https://try.count.ly/content');
      const pw: number | undefined = AppStorage.Get<number>(OverlayKeys.CONTENT_P_W);
      expect(pw !== undefined && pw > 0).assertTrue();
    });

    it('previewContent_emptyId_skips', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      await h.instance.previewContent('');
      await flushTick(30);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length).assertEqual(0);
    });

    it('previewContent_withId_sendsPreviewRequest', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.previewContent('contentXYZ');
      await flushTick(30);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length).assertEqual(1);
      expect(calls[0].data.indexOf('content_id=contentXYZ') !== -1).assertTrue();
      expect(calls[0].data.indexOf('preview=true') !== -1).assertTrue();
    });

    it('exitContentZone_clearsOverlayState', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      h.instance.exitContentZone();
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('consentRevoked_exitsZone', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      h.instance.removeConsent(['content']);
      await flushTick(30);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('invalidResponse_dropsSilently', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = '{"result":"Success"}';
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('handleContentOverlayUrl_closeCommand_hidesOverlay', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=event&event=%5B%5D&close=1'
      );
      expect(handled).assertTrue();
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('handleContentOverlayUrl_eventAction_recordsEvent', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const before: number = h.network.calls.length;
      const encoded: string = encodeURIComponent(JSON.stringify([
        { key: 'content_btn_click', sg: { label: 'hello' } }
      ]));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=event&event=${encoded}`
      );
      expect(handled).assertTrue();
      await flushTick(100);
      const eventCalls = h.network.calls.slice(before)
        .filter((c) => c.data.indexOf('content_btn_click') !== -1);
      expect(eventCalls.length >= 1).assertTrue();
    });

    it('handleContentOverlayUrl_resizeMe_updatesPlacement', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const encoded: string = encodeURIComponent(JSON.stringify({
        p: { x: 10, y: 20, w: 100, h: 200 },
        l: { x: 30, y: 40, w: 200, h: 100 }
      }));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=resize_me&resize_me=${encoded}`
      );
      expect(handled).assertTrue();
      const pw: number | undefined = AppStorage.Get<number>(OverlayKeys.CONTENT_P_W);
      expect(pw !== undefined && pw > 0).assertTrue();
    });

    it('handleContentOverlayUrl_regularUrl_returnsFalse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl('https://example.com/regular-nav');
      expect(handled).assertFalse();
    });

    it('handleContentOverlayUrl_externalMarker_opensExternal', 0, async () => {
      resetStore();
      let opened: string = '';
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.instance.setExternalUrlOpener((url: string) => { opened = url; });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl('https://example.com/page?foo=bar&cly_x_int=1');
      expect(handled).assertTrue();
      expect(opened).assertEqual('https://example.com/page?foo=bar');
    });

    // ======== previewContent public API tests (from ModuleContentTests.java) ========

    it('previewContent_noConsent_omitsFetch', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      await h.instance.previewContent('test_content_id');
      await flushTick(30);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length).assertEqual(0);
    });

    it('previewContent_alreadyInContentZone_skips', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      const before: number = h.network.calls.length;
      await h.instance.previewContent('test_content_id');
      await flushTick(30);
      const after = h.network.calls.slice(before)
        .filter((c) => c.endpoint === '/o/sdk/content');
      expect(after.length).assertEqual(0);
    });

    // ======== validateResponse equivalents (from ModuleContentTests.java) ========
    // The HOS parser drops any response missing either `html` or `geo` (or with
    // only empty geo placements), assert the overlay stays inactive in each case.

    it('validateResponse_missingGeo_dropsResponse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({ html: 'https://example.com/content' });
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('validateResponse_missingHtml_dropsResponse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({
        geo: { p: { x: 0, y: 0, w: 360, h: 640 }, l: { x: 0, y: 0, w: 640, h: 360 } }
      });
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('validateResponse_emptyObject_dropsResponse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = '{}';
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    // ======== Origin validation (dev guide §Origin Validation) ========

    it('originValidation_foreignHost_rejectsWithoutAllowlist', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = JSON.stringify({
        html: 'https://evil.example/malicious',
        geo: { p: { x: 0, y: 0, w: 360, h: 640 }, l: { x: 0, y: 0, w: 640, h: 360 } }
      });
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('originValidation_explicitAllowlist_permitsForeignHost', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.addAllowedOrigins(['https://cdn.example.net']);
      });
      h.network.nextBody = JSON.stringify({
        html: 'https://cdn.example.net/content/widget.html',
        geo: { p: { x: 0, y: 0, w: 360, h: 640 }, l: { x: 0, y: 0, w: 640, h: 360 } }
      });
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      expect(AppStorage.Get<string>(OverlayKeys.CONTENT_URL))
        .assertEqual('https://cdn.example.net/content/widget.html');
    });

    it('originValidation_prefixSubstring_rejected', 0, async () => {
      // Guards against the common mistake of a naive startsWith(): the
      // allowlisted origin 'https://foo.com' must NOT match a URL like
      // 'https://foo.com.evil.com/...'.
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.addAllowedOrigins(['https://foo.com']);
      });
      h.network.nextBody = JSON.stringify({
        html: 'https://foo.com.evil.com/content',
        geo: { p: { x: 0, y: 0, w: 360, h: 640 }, l: { x: 0, y: 0, w: 640, h: 360 } }
      });
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    // ======== fetch URL params (from ModuleContentTests.java) ========

    it('enterContentZone_includesCategoryAndLanguage', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.setCategories(['cat_a', 'cat_b']);
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const calls = h.network.calls.filter((c) => c.endpoint === '/o/sdk/content');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf('category=') !== -1).assertTrue();
      expect(calls[0].data.indexOf('cat_a') !== -1).assertTrue();
      expect(calls[0].data.indexOf('cat_b') !== -1).assertTrue();
      expect(calls[0].data.indexOf('la=') !== -1).assertTrue();
    });

    // ======== URL-intercept protocol tests (from ContentOverlayViewTests.java) ========

    it('handleContentOverlayUrl_eventAction_segmentationField_recordsEvent', 0, async () => {
      // Alternative "segmentation" field name (long form), should be accepted.
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const before: number = h.network.calls.length;
      const encoded: string = encodeURIComponent(JSON.stringify([
        { key: 'click', segmentation: { button: 'submit' } }
      ]));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=event&event=${encoded}`
      );
      expect(handled).assertTrue();
      await flushTick(100);
      const eventCalls = h.network.calls.slice(before)
        .filter((c) => c.data.indexOf('submit') !== -1);
      expect(eventCalls.length >= 1).assertTrue();
    });

    it('handleContentOverlayUrl_multipleEvents_recordsAll', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const before: number = h.network.calls.length;
      const encoded: string = encodeURIComponent(JSON.stringify([
        { key: 'e1', sg: { k: 'v1' } },
        { key: 'e2', sg: { k: 'v2' } }
      ]));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=event&event=${encoded}`
      );
      expect(handled).assertTrue();
      await flushTick(100);
      const e1 = h.network.calls.slice(before).filter((c) => c.data.indexOf('e1') !== -1);
      const e2 = h.network.calls.slice(before).filter((c) => c.data.indexOf('e2') !== -1);
      expect(e1.length >= 1).assertTrue();
      expect(e2.length >= 1).assertTrue();
    });

    it('handleContentOverlayUrl_combinedEventAndClose_bothExecute', 0, async () => {
      resetStore();
      let cbStatus: ContentStatus | null = null;
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.setContentCallback((status: ContentStatus) => { cbStatus = status; });
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const before: number = h.network.calls.length;
      const encoded: string = encodeURIComponent(JSON.stringify([
        { key: 'btn_click', sg: { k: 'v' } }
      ]));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=event&event=${encoded}&close=1`
      );
      expect(handled).assertTrue();
      await flushTick(100);
      const evt = h.network.calls.slice(before).filter((c) => c.data.indexOf('btn_click') !== -1);
      expect(evt.length >= 1).assertTrue();
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
      expect(cbStatus !== null).assertTrue();
    });

    it('handleContentOverlayUrl_linkAction_opensExternal', 0, async () => {
      resetStore();
      let opened: string = '';
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.instance.setExternalUrlOpener((url: string) => { opened = url; });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const link: string = encodeURIComponent('https://elsewhere.test/page');
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=link&link=${link}`
      );
      expect(handled).assertTrue();
      expect(opened).assertEqual('https://elsewhere.test/page');
    });

    it('handleContentOverlayUrl_unknownAction_returnsTrue', 0, async () => {
      // Unknown action is still a recognized countly command URL and must be
      // consumed by the handler (returns true) rather than letting the webview
      // navigate.
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=unknown_xyz'
      );
      expect(handled).assertTrue();
    });

    it('handleContentOverlayUrl_bareClose_hidesOverlay', 0, async () => {
      // URL with `close=1` but no cly_x_action_event, still honored when the
      // command base matches (protocol allows a plain-close form).
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?close=1'
      );
      expect(handled).assertTrue();
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    it('handleContentOverlayUrl_nullOrEmpty_returnsFalse', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      expect(h.instance.handleContentOverlayUrl('')).assertFalse();
    });

    it('handleContentOverlayUrl_malformedEventJson_returnsTrueNoCrash', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=event&event=not_valid_json'
      );
      expect(handled).assertTrue();
    });

    it('handleContentOverlayUrl_malformedResizeJson_returnsTrueNoCrash', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=resize_me&resize_me={broken}'
      );
      expect(handled).assertTrue();
    });

    it('handleContentOverlayUrl_emptyEventArray_returnsTrueNoCrash', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const handled: boolean = h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&action=event&event=%5B%5D'
      );
      expect(handled).assertTrue();
    });

    it('handleContentOverlayUrl_eventMissingSegmentation_returnsTrueNoCrash', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      const encoded: string = encodeURIComponent(JSON.stringify([{ key: 'test_key' }]));
      const handled: boolean = h.instance.handleContentOverlayUrl(
        `https://countly_action_event/?cly_x_action_event=1&action=event&event=${encoded}`
      );
      expect(handled).assertTrue();
    });

    // ======== Content callback (dev guide: fires on CLOSED / COMPLETED) ========

    it('contentCallback_firesWithCompletedOnProtocolClose', 0, async () => {
      resetStore();
      let cbStatus: ContentStatus | null = null;
      let cbData: Record<string, Object> | null = null;
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.setContentCallback((status: ContentStatus, data: Record<string, Object>) => {
          cbStatus = status;
          cbData = data;
        });
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      h.instance.handleContentOverlayUrl(
        'https://countly_action_event/?cly_x_action_event=1&close=1'
      );
      expect(cbStatus).assertEqual(ContentStatus.COMPLETED);
      expect(cbData !== null).assertTrue();
    });

    it('contentCallback_firesWithClosedOnUserDismiss', 0, async () => {
      resetStore();
      let cbStatus: ContentStatus | null = null;
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.setContentCallback((status: ContentStatus) => { cbStatus = status; });
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      h.instance.onContentOverlayClosed(ContentStatus.CLOSED, {});
      expect(cbStatus).assertEqual(ContentStatus.CLOSED);
    });

    it('contentCallback_firesOnLoadTimeout', 0, async () => {
      resetStore();
      let cbStatus: ContentStatus | null = null;
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.setContentCallback((status: ContentStatus) => { cbStatus = status; });
      });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      h.instance.onContentOverlayLoadTimedOut();
      expect(cbStatus).assertEqual(ContentStatus.CLOSED);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    // ======== Device-ID change without merge exits the zone ========

    it('deviceIdChangeWithoutMerge_exitsZone', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      await h.instance.changeWithoutMerge('new-device-id');
      await flushTick(30);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertFalse();
    });

    // ======== refreshContentZone ========

    it('refreshContentZone_disabled_isNoop', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.giveAll();
        cfg.contentForTest.disableRefreshContentZone();
      });
      h.network.nextBody = VALID_BODY;
      const before: number = h.network.calls.length;
      await h.instance.refreshContentZone();
      await flushTick(30);
      const after = h.network.calls.slice(before)
        .filter((c) => c.endpoint === '/o/sdk/content');
      expect(after.length).assertEqual(0);
    });

    it('refreshContentZone_whenOverlayActive_skips', 0, async () => {
      resetStore();
      const h: Harness = await buildHarness((cfg) => { cfg.consent.giveAll(); });
      h.network.nextBody = VALID_BODY;
      await h.instance.enterContentZone();
      await flushTick(4300);
      expect(AppStorage.Get<boolean>(OverlayKeys.CONTENT_ACTIVE) === true).assertTrue();
      const before: number = h.network.calls.length;
      await h.instance.refreshContentZone();
      await flushTick(30);
      const after = h.network.calls.slice(before)
        .filter((c) => c.endpoint === '/o/sdk/content');
      expect(after.length).assertEqual(0);
    });
  });
}
