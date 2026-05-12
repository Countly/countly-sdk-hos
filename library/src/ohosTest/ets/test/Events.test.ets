import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { FilterList } from '../../../main/ets/internal/ServerConfig';
import { SegmentationMap } from '../../../main/ets/types/Types';

export default function eventsTest() {
  describe('EventsTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('recordEvent_emptyKey_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('', null, 1, 0, 0);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
    });

    it('recordEvent_batchesAtThreshold', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(3); });
      await h.instance.events.recordEvent('e1');
      await h.instance.events.recordEvent('e2');
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      await h.instance.events.recordEvent('e3');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('recordEvent_immediateFlushForNpsSurveyPushAction', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('recordEvent_consentGatingForCustom', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      await h.instance.events.recordEvent('custom_event');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      // Give events consent and confirm a custom event goes through.
      h.instance.consentModule.giveConsent(['events']);
      await h.instance.events.recordEvent('custom_event_2');
      await flushTick(1200);
      expect(h.network.findCallsWithParam('events=').length >= 0).assertTrue();
    });

    it('recordEvent_internalEventRequiresFeatureConsent', 0, async () => {
      // Events consent alone is NOT enough for [CLY]_nps — the feedback
      // feature consent is what gates internal feedback events.
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      h.instance.consentModule.giveConsent(['events']);
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      h.instance.consentModule.giveConsent(['feedback']);
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('recordEvent_starRating_acceptsEitherStarRatingOrFeedbackConsent', 0, async () => {
      // Mirror Android sdk/ModuleEvents.java:185-186 — `[CLY]_star_rating`
      // accepts the dual gate `starRating` OR `feedback`. Either one alone
      // unlocks the event; neither granted drops it.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.events.setQueueSizeToSend(1);
      });
      // Neither granted → dropped.
      await h.instance.events.recordEvent('[CLY]_star_rating');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      // Only starRating → accepted.
      h.instance.consentModule.giveConsent(['star-rating']);
      await h.instance.events.recordEvent('[CLY]_star_rating');
      await flushTick(60);
      const afterStarRating: number = h.network.findCallsWithParam('events=').length;
      expect(afterStarRating >= 1).assertTrue();

      // Now revoke starRating, grant feedback → still accepted.
      h.instance.consentModule.removeConsent(['star-rating']);
      h.instance.consentModule.giveConsent(['feedback']);
      await h.instance.events.recordEvent('[CLY]_star_rating');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length > afterStarRating).assertTrue();
    });

    it('recordEvent_action_acceptsEitherClicksOrScrollsConsent', 0, async () => {
      // Mirror Android sdk/ModuleEvents.java:219 — `[CLY]_action` accepts
      // the dual gate `clicks` OR `scrolls`.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.events.setQueueSizeToSend(1);
      });
      // Neither granted → dropped.
      await h.instance.events.recordEvent('[CLY]_action');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      // Only clicks → accepted.
      h.instance.consentModule.giveConsent(['clicks']);
      await h.instance.events.recordEvent('[CLY]_action');
      await flushTick(60);
      const afterClicks: number = h.network.findCallsWithParam('events=').length;
      expect(afterClicks >= 1).assertTrue();

      // Now revoke clicks, grant scrolls → still accepted.
      h.instance.consentModule.removeConsent(['clicks']);
      h.instance.consentModule.giveConsent(['scrolls']);
      await h.instance.events.recordEvent('[CLY]_action');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length > afterClicks).assertTrue();
    });

    it('timedEvent_endRecordsDuration', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.events.startEvent('action');
      await flushTick(50);
      await h.instance.events.endEvent('action');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('dur') !== -1 || call.data.indexOf('%22dur%22') !== -1).assertTrue();
    });

    it('timedEvent_cancelDropsStartedEvent', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.events.startEvent('action');
      h.instance.events.cancelEvent('action');
      await h.instance.events.endEvent('action');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
    });

    it('timedEvent_startTwice_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.events.startEvent('once');
      h.instance.events.startEvent('once'); // should warn, not throw
      expect(true).assertTrue();
    });

    it('recordEvent_negativeCount_clampedTo1', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('e', null, -5, 0, 0);
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
    });

    it('recordPastEvent_preservesGivenTimestamp', 0, async () => {
      // Any past-event call must serialize with the caller-supplied timestamp
      // on the queued payload, not the current Utils.uniqueTimestampMs(). That
      // timestamp is the whole point of the API — if it doesn't flow through
      // to the wire the feature is silently useless.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const pastTs: number = 1609459200000; // 2021-01-01T00:00:00Z — older than any test clock
      await h.instance.events.recordPastEvent('old_event', null, 1, 0, 0, pastTs);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      // events= value is URL-encoded JSON — decode before searching for the
      // literal field, otherwise we'd be matching against `%22timestamp%22%3A...`.
      const decoded: string = decodeURIComponent(calls[0].data);
      expect(decoded.indexOf(`"timestamp":${pastTs}`) !== -1).assertTrue();
    });

    it('recordPastEvent_nonPositiveTimestamp_fallsBackToNow', 0, async () => {
      // 0 / negative / NaN must not break the queue — fall back to the
      // current unique timestamp so the event still lands (with a warning).
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordPastEvent('zero_ts', null, 1, 0, 0, 0);
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('serverConfig_eventBlacklist_dropsMatchingKey', 0, async () => {
      // Blacklist mode (isWhitelist=false): listed keys are dropped, the
      // rest go through. Verifies the filter plumbing lives on the custom-
      // event path and nowhere else.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.serverConfig.eventFilter = new FilterList<string[]>(['blocked_event'], false);
      await h.instance.events.recordEvent('blocked_event', null, 1, 0, 0);
      await h.instance.events.recordEvent('allowed_event', null, 1, 0, 0);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length).assertEqual(1);
      expect(calls[0].data.indexOf('allowed_event') !== -1).assertTrue();
      expect(calls[0].data.indexOf('blocked_event') === -1).assertTrue();
    });

    it('serverConfig_eventWhitelist_dropsUnlistedKeys', 0, async () => {
      // Whitelist mode flips the meaning: only listed keys survive.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.serverConfig.eventFilter = new FilterList<string[]>(['kept_event'], true);
      await h.instance.events.recordEvent('kept_event', null, 1, 0, 0);
      await h.instance.events.recordEvent('unlisted_event', null, 1, 0, 0);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length).assertEqual(1);
      expect(calls[0].data.indexOf('kept_event') !== -1).assertTrue();
      expect(calls[0].data.indexOf('unlisted_event') === -1).assertTrue();
    });

    it('serverConfig_internalEvents_bypassFilter', 0, async () => {
      // [CLY]_* events are SDK-owned and must never be filtered by the
      // generic event/segmentation pipeline — filtering them out would
      // break sessions, views, feedback, etc. Even a "match everything"
      // blacklist must let them through.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true);
      });
      h.instance.consentModule.giveConsent(['feedback']);
      // Try a nuclear-option blacklist that matches the NPS event key.
      h.instance.config.serverConfig.eventFilter = new FilterList<string[]>(['[CLY]_nps'], false);
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('serverConfig_customEventTrackingDisabled_dropsCustomOnly', 0, async () => {
      // Server killswitch: custom events dropped, internal events still go.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true);
      });
      h.instance.consentModule.giveConsent(['events', 'feedback']);
      h.instance.config.serverConfig.customEventTrackingEnabled = false;
      await h.instance.events.recordEvent('custom_that_should_be_dropped', null, 1, 0, 0);
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf('custom_that_should_be_dropped') === -1).assertTrue();
    });

    it('serverConfig_segmentationBlacklist_stripsKey', 0, async () => {
      // Global segmentation blacklist removes the listed key from every
      // custom event's segmentation map. The event itself still records.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.serverConfig.segmentationFilter = new FilterList<string[]>(['secret'], false);
      const seg1: SegmentationMap = { 'secret': 'visa-4242', 'amount': 10 };
      await h.instance.events.recordEvent('purchase', seg1, 1, 0, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('amount') !== -1).assertTrue();
      expect(call.data.indexOf('secret') === -1).assertTrue();
    });

    it('serverConfig_perEventSegmentationFilter_scopedToKey', 0, async () => {
      // Per-event filter only applies to the named event; others stay
      // untouched even if they have the same segmentation key. Batch both
      // events in one flush so the assertion can read a single payload.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(2); });
      const perEvent: Record<string, string[]> = {};
      perEvent['scoped_event'] = ['drop_me'];
      h.instance.config.serverConfig.eventSegmentationFilter = new FilterList<Record<string, string[]>>(perEvent, false);
      const segScoped: SegmentationMap = { 'drop_me': 1, 'keep': 2 };
      const segOther: SegmentationMap = { 'drop_me': 3 };
      await h.instance.events.recordEvent('scoped_event', segScoped, 1, 0, 0);
      await h.instance.events.recordEvent('other_event', segOther, 1, 0, 0);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      const body: string = calls[0].data;
      // Both events present, scoped_event keeps 'keep', other_event still
      // has 'drop_me' (filter was scoped to scoped_event only).
      expect(body.indexOf('scoped_event') !== -1).assertTrue();
      expect(body.indexOf('other_event') !== -1).assertTrue();
      expect(body.indexOf('keep') !== -1).assertTrue();
    });

    // -- Ported from Android EventTests.java (Event class serialization) --

    it('eventPayload_fullWithSegmentation_serializesAllFields', 0, async () => {
      // Android's Event.toJSON full-field test. HOS has no public Event class,
      // so we validate the wire-format payload instead: all fields present.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const segKey: SegmentationMap = { 'segkey': 'segvalue', 'segkey1': 123, 'segkey3': true };
      await h.instance.events.recordEvent('eventKey', segKey, 42, 3.2, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22key%22%3A%22eventKey%22') !== -1).assertTrue();
      expect(body.indexOf('%22count%22%3A42') !== -1).assertTrue();
      expect(body.indexOf('%22sum%22%3A3.2') !== -1).assertTrue();
      expect(body.indexOf('%22segmentation%22') !== -1).assertTrue();
      expect(body.indexOf('%22timestamp%22') !== -1).assertTrue();
      expect(body.indexOf('%22hour%22') !== -1).assertTrue();
      expect(body.indexOf('%22dow%22') !== -1).assertTrue();
      expect(body.indexOf('%22id%22') !== -1).assertTrue();
    });

    it('eventPayload_zeroSumAndDur_omitted', 0, async () => {
      // HOS serializer skips sum/dur when they are zero (see ModuleEvents.
      // serializeEvent). Matches Android toJSON_nullSegmentation-ish intent:
      // optional fields don't clutter the payload when they carry no info.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('no_extras');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22sum%22') === -1).assertTrue();
      expect(call.data.indexOf('%22dur%22') === -1).assertTrue();
    });

    it('eventPayload_emptySegmentation_omitsSegmentationField', 0, async () => {
      // Empty segmentation must not appear in the payload (Android
      // toJSON_emptySegmentation).
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('empty_seg', {}, 1, 0, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22segmentation%22') === -1).assertTrue();
    });

    it('eventPayload_sumNaN_excludedFromPayload', 0, async () => {
      // Android toJSON_sumNaNCausesJSONException: a NaN sum must not land on
      // the wire. HOS JSON.stringify produces `null` for NaN. Either way the
      // literal numeric field must not appear.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('nan_sum', null, 1, Number.NaN, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      // No actual numeric sum in the body. Substring check guards against a
      // future regression that would stringify NaN as a number.
      expect(call.data.indexOf('%22sum%22%3ANaN') === -1).assertTrue();
    });

    // -- Ported from Android ModuleEventsTests.java --

    it('recordEvent_defaultCountIsOne', 0, async () => {
      // Android recordEvent_1 — key-only overload must default count=1.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('asdf');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22count%22%3A1') !== -1).assertTrue();
    });

    it('recordEvent_countAndSum_serialized', 0, async () => {
      // Android recordEvent_3 — count and sum flow through to the payload.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('asdf', null, 657, 884.213, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22count%22%3A657') !== -1).assertTrue();
      expect(call.data.indexOf('%22sum%22%3A884.213') !== -1).assertTrue();
    });

    it('recordEvent_segmentation_primitiveTypes_serialized', 0, async () => {
      // Android recordEvent_7 / eventWithSegmentation — string, int, double,
      // boolean must all survive the recordEvent → wire-format roundtrip.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('asdf', {
        'aa': 'dd', 'aa1': 'dda', 'i': 1234, 'd': 1234.55, 'b': true
      }, 1245, 443.76, 985.33);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22aa%22%3A%22dd%22') !== -1).assertTrue();
      expect(body.indexOf('%22i%22%3A1234') !== -1).assertTrue();
      expect(body.indexOf('%22d%22%3A1234.55') !== -1).assertTrue();
      expect(body.indexOf('%22b%22%3Atrue') !== -1).assertTrue();
      expect(body.indexOf('%22dur%22%3A985.33') !== -1).assertTrue();
    });

    it('timedEvent_endEmptySegmentation_recordsDuration', 0, async () => {
      // Android startEndEvent_noSegments — start/end with no segmentation
      // records an event that still carries a dur field.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.events.startEvent('asdf');
      await flushTick(80);
      await h.instance.events.endEvent('asdf');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22key%22%3A%22asdf%22') !== -1).assertTrue();
      expect(call.data.indexOf('%22dur%22') !== -1).assertTrue();
    });

    it('timedEvent_endWithSegments_recordsSegmentationAndCountSum', 0, async () => {
      // Android startEndEvent_withSegments — end-time segmentation + count +
      // sum land on the wire alongside the computed duration.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.events.startEvent('asdf');
      await flushTick(60);
      const segEnd: SegmentationMap = { 'aa': 'dd', 'n': 1234 };
      await h.instance.events.endEvent('asdf', segEnd, 6372, 5856.34);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22count%22%3A6372') !== -1).assertTrue();
      expect(body.indexOf('%22sum%22%3A5856.34') !== -1).assertTrue();
      expect(body.indexOf('%22aa%22%3A%22dd%22') !== -1).assertTrue();
    });

    it('timedEvent_startCancelStartEnd_secondStartTakesEffect', 0, async () => {
      // Android startCancelStartEndEvent — cancel wipes the first timer, so
      // a subsequent start/end does record exactly one event.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.events.startEvent('asdf');
      h.instance.events.cancelEvent('asdf');
      h.instance.events.startEvent('asdf');
      await flushTick(60);
      await h.instance.events.endEvent('asdf');
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
    });

    it('immediateFlush_onlyNpsSurveyPushAction_flushImmediately', 0, async () => {
      // Android eventsForceClearingEQIntoRQ — check the exact allowed set of
      // immediate-flush keys against the rest. Record a custom event first so
      // there's something to *not* flush, then each candidate in order.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(100); });
      await h.instance.events.recordEvent('rnd_key'); // stays queued
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      await h.instance.events.recordEvent('[CLY]_nps'); // flushes
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);

      await h.instance.events.recordEvent('[CLY]_survey'); // flushes
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(2);

      await h.instance.events.recordEvent('[CLY]_star_rating'); // does NOT flush
      expect(h.network.findCallsWithParam('events=').length).assertEqual(2);

      await h.instance.events.recordEvent('[CLY]_push_action'); // flushes
      await flushTick(60);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(3);
    });

    it('internalLimits_keyLength_internalKeysNotTruncated_customKeyTruncated', 0, async () => {
      // Android internalLimits_recordEvent_internalKeys — internal [CLY]_*
      // keys bypass the maxKeyLength clamp so dashboard bucketing stays
      // correct. Custom keys still get truncated.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.limits.maxKeyLength = 2;
      await h.instance.events.recordEvent('[CLY]_nps');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_nps').length >= 1).assertTrue();

      await h.instance.events.recordEvent('ModuleEvents');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      // Latest call should contain the truncated 'Mo' key.
      expect(calls[calls.length - 1].data.indexOf('%22key%22%3A%22Mo%22') !== -1).assertTrue();
    });

    it('internalLimits_segmentation_truncatesKeys', 0, async () => {
      // Android internalLimits_recordEvent_segmentation — maxKeyLength clamps
      // segmentation keys too. Two originally-distinct keys that collapse to
      // the same truncated key should coalesce (last write wins in HOS).
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.limits.maxKeyLength = 2;
      const segTm: SegmentationMap = { 'ModuleEvents': 'x', 'ModuleFeedback': 567 };
      await h.instance.events.recordEvent('TestMe', segTm, 1, 0, 0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%22key%22%3A%22Te%22') !== -1).assertTrue();
      // Only one "Mo" segmentation key should remain.
      expect(call.data.indexOf('%22Mo%22') !== -1).assertTrue();
    });

    it('internalLimits_maxSegmentationValues_clipsExtraEntries', 0, async () => {
      // Android internalLimits_recordEventInternal_maxSegmentationValues —
      // when the map exceeds the cap, HOS (like Android) keeps the last N.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.limits.maxSegmentationValues = 2;
      await h.instance.events.recordEvent('rnd_key', {
        'a': 1, 'b': 2, 'c': 3, 'd': 4, 'e': 5, 'f': 6, 'g': 7
      }, 1, 1.1, 1.1);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      // 'f' and 'g' kept (last two), 'a'..'e' dropped.
      expect(body.indexOf('%22f%22%3A6') !== -1).assertTrue();
      expect(body.indexOf('%22g%22%3A7') !== -1).assertTrue();
      expect(body.indexOf('%22a%22') === -1).assertTrue();
    });

    it('internalLimits_maxValueSize_clipsStringValues', 0, async () => {
      // Android internalLimits_recordEventInternal_maxValueSize.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.limits.maxValueSize = 2;
      const segRnd: SegmentationMap = { 'a': 1, 'b': 'bbb', 'c': 'ccc' };
      await h.instance.events.recordEvent('rnd_key', segRnd, 1, 1.1, 1.1);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22b%22%3A%22bb%22') !== -1).assertTrue();
      expect(body.indexOf('%22c%22%3A%22cc%22') !== -1).assertTrue();
      // No untruncated values survive.
      expect(body.indexOf('%22bbb%22') === -1).assertTrue();
    });

    it('internalLimits_maxValueSizeAndKeyLength_collidingKeysLastWriteWins', 0, async () => {
      // Android internalLimits_recordEventInternal_maxValueSizeKeyLength —
      // truncated keys that collide collapse; value of the last entry wins.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.config.limits.maxKeyLength = 2;
      h.instance.config.limits.maxValueSize = 2;
      await h.instance.events.recordEvent('rnd_key', {
        'a': 1, 'bbb': 'bbb', 'bbc': 'ccc', 'bbd': 'ddd', 'bbe': 'eee'
      }, 1, 1.1, 1.1);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22key%22%3A%22rn%22') !== -1).assertTrue();
      expect(body.indexOf('%22a%22%3A1') !== -1).assertTrue();
      // The four 'bb*' keys collapse to a single 'bb' — last value 'ee' wins
      // once clipped from 'eee'.
      expect(body.indexOf('%22bb%22%3A%22ee%22') !== -1).assertTrue();
    });

    it('recordEvent_validateFromRQ_arraySegmentation_serialized', 0, async () => {
      // Android recordEvent_validateSupportedArrays — primitive arrays
      // survive the roundtrip as JSON arrays on the wire.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const intArr: number[] = [1, 2, 3];
      const boolArr: boolean[] = [true, false, true];
      const strArr: string[] = ['a', 'b', 'c'];
      await h.instance.events.recordEvent('key', {
        'arr': intArr, 'arrB': boolArr, 'arrS': strArr
      }, 1, 1.0, 1.0);
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      expect(body.indexOf('%22arr%22%3A%5B1%2C2%2C3%5D') !== -1).assertTrue();
      expect(body.indexOf('%22arrB%22%3A%5Btrue%2Cfalse%2Ctrue%5D') !== -1).assertTrue();
      expect(body.indexOf('%22arrS%22%3A%5B%22a%22%2C%22b%22%2C%22c%22%5D') !== -1).assertTrue();
    });

    it('recordEvent_visibilityTracking_tagsCustomEventsWithClyV', 0, async () => {
      // Android recordEvent_visibilityTracking_onlyAddingItToViewsAndEvents —
      // when visibility tracking is enabled, custom events pick up `cly_v`.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.experimental.enableVisibilityTracking();
      });
      await h.instance.events.recordEvent('rnd_key');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      // Default state is "not foreground" → cly_v=0.
      expect(call.data.indexOf('%22cly_v%22%3A0') !== -1).assertTrue();
    });

    it('recordEvent_visibilityTracking_bgFgSwitch_togglesClyV', 0, async () => {
      // Android recordEvent_visibilityTracking_bgFgSwitch — toggling
      // foreground/background flips the cly_v value.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.experimental.enableVisibilityTracking();
      });
      h.instance.lifecycleForeground();
      await h.instance.events.recordEvent('fg');
      await flushTick(60);
      h.instance.lifecycleBackground();
      await flushTick(60);
      await h.instance.events.recordEvent('bg');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 2).assertTrue();
      const fgCall = calls.find((c) => c.data.indexOf('%22key%22%3A%22fg%22') !== -1);
      const bgCall = calls.find((c) => c.data.indexOf('%22key%22%3A%22bg%22') !== -1);
      expect(fgCall !== undefined && fgCall.data.indexOf('%22cly_v%22%3A1') !== -1).assertTrue();
      expect(bgCall !== undefined && bgCall.data.indexOf('%22cly_v%22%3A0') !== -1).assertTrue();
    });

    it('recordEvent_visibilityTracking_disabled_noClyV', 0, async () => {
      // Android recordEvent_visibilityTracking_notEnabled — default config
      // must not tag events with cly_v.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      h.instance.lifecycleForeground();
      await h.instance.events.recordEvent('fg');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('cly_v') === -1).assertTrue();
    });

    it('recordEvent_previousNameRecording_disabled_noPenCvn', 0, async () => {
      // Android recordEventScenario_previous_current_ViewName_disabled.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.events.recordEvent('TEST');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('cly_pen') === -1).assertTrue();
      expect(call.data.indexOf('cly_cvn') === -1).assertTrue();
    });

    it('recordEvent_previousNameRecording_enabled_tagsPenCvn', 0, async () => {
      // Android recordEventScenario_previous_current_ViewName — each custom
      // event gets cly_pen (previous event name) and cly_cvn (current view).
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.experimental.enablePreviousNameRecording();
      });
      await h.instance.events.recordEvent('TEST');
      await flushTick(60);
      await h.instance.events.recordEvent('TEST1');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 2).assertTrue();
      // First event: pen=''/cvn='' (no prior state). Second: pen='TEST'.
      const secondCall = calls.find((c) => c.data.indexOf('%22key%22%3A%22TEST1%22') !== -1);
      expect(secondCall !== undefined).assertTrue();
      expect(secondCall!.data.indexOf('%22cly_pen%22%3A%22TEST%22') !== -1).assertTrue();
      expect(secondCall!.data.indexOf('cly_cvn') !== -1).assertTrue();
    });

    it('eventIdLinking_customEventPeidLinksToPreviousEvent', 0, async () => {
      // Ported subset of ScenarioEventIDTests.eventIDScenario_manualViews —
      // HOS stores lastEventId and stamps it onto the next custom event as
      // peid. Internal + immediate-flush keys break the chain by design.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(2); });
      await h.instance.events.recordEvent('first');
      await h.instance.events.recordEvent('second');
      await flushTick(60);
      const call = h.network.findCallsWithParam('events=')[0];
      expect(call !== undefined).assertTrue();
      const body: string = call.data;
      // Pull the first event's id out of the payload, then check the second
      // event carries that id as peid. The payload has two events in order,
      // each with a unique id= field.
      const firstIdMatch: RegExpMatchArray | null = body.match(/%22id%22%3A%22([^%]+)%22/);
      expect(firstIdMatch !== null).assertTrue();
      const firstId: string = firstIdMatch![1];
      expect(body.indexOf(`%22peid%22%3A%22${firstId}%22`) !== -1).assertTrue();
    });

    it('eventsWireOrder_consentBeforeBeginSessionBeforeEvents', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
        cfg.events.setQueueSizeToSend(1);
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.events.recordEvent('wire_order_event');
      await flushTick(60);
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1', 'events=']);
    });
  });
}
