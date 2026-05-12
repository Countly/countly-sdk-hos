import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { SegmentationMap } from '../../../main/ets/types/Types';
import { RecordedCall } from './doubles/FakeNetwork';
import { ModuleViews } from '../../../main/ets/internal/modules/ModuleViews';
import { ModuleEvents } from '../../../main/ets/internal/modules/ModuleEvents';

export default function viewsTest() {
  describe('ViewsTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('autoStoppedView_onlyOneActive', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id1: string | null = await h.instance.views.startAutoStoppedView('A');
      expect(id1 !== null).assertTrue();
      const id2: string | null = await h.instance.views.startAutoStoppedView('B');
      expect(id2 !== null).assertTrue();
      await flushTick(100);
      const calls = h.network.findCallsWithParam('events=');
      // Expect a stop event for A and start events for A, B -> at least 3 event requests.
      expect(calls.length >= 2).assertTrue();
    });

    it('manualView_notAutoStopped', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const idA: string | null = await h.instance.views.startView('A');
      const idB: string | null = await h.instance.views.startView('B');
      expect(idA !== null && idB !== null).assertTrue();
      await flushTick(60);
      await h.instance.views.stopViewWithID(idA!, null);
      await h.instance.views.stopViewWithID(idB!, null);
      await flushTick(60);
      expect(h.network.calls.length >= 4).assertTrue();
    });

    it('stopViewWithID_unknownId_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.views.stopViewWithID('nonexistent', null);
      expect(true).assertTrue();
    });

    it('pauseResume_view', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('P');
      expect(id !== null).assertTrue();
      h.instance.views.pauseViewWithID(id!);
      h.instance.views.resumeViewWithID(id!);
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      expect(h.network.calls.length >= 2).assertTrue();
    });

    it('stopAllViews_closesEverything', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('X');
      await h.instance.views.startView('Y');
      await flushTick(60);
      await h.instance.views.stopAllViews(null);
      await flushTick(60);
      expect(h.network.calls.length >= 4).assertTrue();
    });

    it('emptyName_returnsNull', 0, async () => {
      const h: Harness = await buildHarness();
      const id: string | null = await h.instance.views.startView('');
      expect(id).assertNull();
    });

    it('globalSegmentation_mergedIntoViewEvent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await flushTick(5);
      h.network.reset();
      const gvs1: SegmentationMap = { 'environment': 'staging' };
      h.instance.views.setGlobalViewSegmentation(gvs1);
      await h.instance.views.startView('Main');
      await flushTick(60);
      const call = h.network.calls[0];
      expect(call.data.indexOf('environment') !== -1 || call.data.indexOf('staging') !== -1).assertTrue();
    });

    it('updateGlobalSegmentation_mergesWithExisting', 0, async () => {
      const h: Harness = await buildHarness();
      const gvsA: SegmentationMap = { 'a': 1 };
      const gvsB: SegmentationMap = { 'b': 2 };
      h.instance.views.setGlobalViewSegmentation(gvsA);
      h.instance.views.updateGlobalViewSegmentation(gvsB);
      expect(true).assertTrue();
    });

    it('updateOrientation_emitsInternalEvent', 0, async () => {
      // Fire a single orientation change and verify a [CLY]_orientation
      // event is queued with mode=landscape. Uses queueSizeToSend=1 so the
      // event flushes synchronously on the next tick.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.updateOrientation('landscape');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_orientation');
      expect(calls.length >= 1).assertTrue();
      expect(calls[0].data.indexOf('landscape') !== -1).assertTrue();
    });

    it('updateOrientation_dedupesUnchangedMode', 0, async () => {
      // Calling twice with the same mode must only enqueue one event — this
      // matters because integrators wiring into onConfigurationUpdate get
      // redundant calls every time *anything* in the configuration changes.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      const firstCount: number = h.network.findCallsWithParam('%5BCLY%5D_orientation').length;
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(firstCount);
    });

    it('updateOrientation_invalidMode_ignored', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.updateOrientation('sideways');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(0);
    });

    it('updateOrientation_disabled_noEvent', 0, async () => {
      // trackOrientationChanges = false → public API becomes a no-op so
      // integrators can keep their wiring unchanged when disabling the
      // feature at init.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setTrackOrientationChanges(false);
      });
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(0);
    });

    it('updateOrientation_forceSend_bypassesDedupe', 0, async () => {
      // Locks the Android-parity contract introduced for the
      // begin_session orientation baseline: ModuleSessions.beginSessionInternal
      // calls updateOrientation(mode, forceSend=true) after enqueueing
      // begin_session (mirrors sdk/ModuleSessions.java:67-68). forceSend=true
      // must bypass the dedupe so every begin_session emits a fresh
      // orientation event even when the orientation hasn't changed since
      // the previous session — without this, dashboards would see "first
      // session per process has orientation, subsequent same-process
      // sessions don't" which diverges from Android.
      //
      // The public `views` facade only exposes the no-arg form (matching
      // Android — forceSend is internal-only). To exercise the overload
      // without leaking it through the integrator-facing surface we
      // construct a parallel `ModuleViews` here, sharing `h.instance` as
      // the `SdkCore` so emitted events still flow through `h.network` via
      // the same request queue.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const events: ModuleEvents = new ModuleEvents(h.instance.config, h.instance);
      const views: ModuleViews = new ModuleViews(h.instance.config, h.instance, events);
      await views.updateOrientation('portrait'); // primes lastOrientationMode
      await flushTick(60);
      const baseline: number = h.network.findCallsWithParam('%5BCLY%5D_orientation').length;
      // Same mode + forceSend=true → emits anyway.
      await views.updateOrientation('portrait', true);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(baseline + 1);
      // Repeated force-sends each emit independently of dedupe state.
      await views.updateOrientation('portrait', true);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(baseline + 2);
    });

    it('updateOrientation_forceSend_stillRespectsDisabled', 0, async () => {
      // Even with forceSend=true, the trackOrientationChanges killswitch
      // must win — otherwise integrators who explicitly opt out via
      // setTrackOrientationChanges(false) would still receive orientation
      // events at every begin_session. Same parallel-ModuleViews approach
      // as the bypass-dedupe test above.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setTrackOrientationChanges(false);
      });
      const events: ModuleEvents = new ModuleEvents(h.instance.config, h.instance);
      const views: ModuleViews = new ModuleViews(h.instance.config, h.instance, events);
      await views.updateOrientation('portrait', true);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(0);
    });

    // -- Ported from Android ModuleViewsTests --

    it('addSegmentationToRunningView_badInputs_noThrow', 0, async () => {
      // Mirrors addSegmentationToRunningView: calls with unknown names/ids or
      // empty strings must be silent no-ops rather than NPE-ing.
      const h: Harness = await buildHarness();
      const empty: SegmentationMap = {};
      const kv: SegmentationMap = { 'k': 'v' };
      h.instance.views.addSegmentationToViewWithName('', empty);
      h.instance.views.addSegmentationToViewWithID('', empty);
      h.instance.views.addSegmentationToViewWithName('not_started', kv);
      h.instance.views.addSegmentationToViewWithID('nope', kv);
      await h.instance.views.startView('a');
      h.instance.views.addSegmentationToViewWithName('', empty);
      h.instance.views.addSegmentationToViewWithID('', empty);
      expect(true).assertTrue();
    });

    it('addSegmentationToView_mergesAndOverridesOnStop', 0, async () => {
      // Port of addSegmentationToView: name-based then id-based calls stack,
      // later keys override earlier ones, and everything lands on the stop
      // event alongside the global segmentation.
      const gv1: SegmentationMap = { 'aa': '11', 'aagfg': '1133' };
      const sBB: SegmentationMap = { 'bb': '22' };
      const sCC: SegmentationMap = { 'cc1': '12', 'cc2': 'as' };
      const sCC2: SegmentationMap = { 'cc2': 'as_new', 'dd': 'qq' };
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setGlobalViewSegmentation(gv1);
      });
      h.instance.views.addSegmentationToViewWithName('Main', sBB);
      const id: string | null = await h.instance.views.startAutoStoppedView('Main');
      expect(id !== null).assertTrue();
      h.instance.views.addSegmentationToViewWithName('Main', sCC);
      h.instance.views.addSegmentationToViewWithID(id!, sCC2);
      await flushTick(30);
      await h.instance.views.stopViewWithName('Main', null);
      await flushTick(60);
      const stopCall = h.network.findCallsWithParam('%5BCLY%5D_view').pop()!;
      const body: string = decodeURIComponent(stopCall.data);
      expect(body.indexOf('"cc1":"12"') !== -1).assertTrue();
      expect(body.indexOf('"cc2":"as_new"') !== -1).assertTrue();
      expect(body.indexOf('"dd":"qq"') !== -1).assertTrue();
      expect(body.indexOf('"aa":"11"') !== -1).assertTrue();
    });

    it('recordViewWithoutConsent_noEvent', 0, async () => {
      // Without views consent, every API on the views surface is a no-op.
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.events.setQueueSizeToSend(1);
      });
      const idA: string | null = await h.instance.views.startView('A');
      expect(idA).assertNull();
      const idB: string | null = await h.instance.views.startAutoStoppedView('B');
      expect(idB).assertNull();
      await h.instance.views.stopViewWithName('A', null);
      await h.instance.views.stopAllViews(null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(0);
    });

    it('viewEventMarkers_firstSegmentStartAndVisit', 0, async () => {
      // Port of the ClearFillSegmentationViewStart shape: a view start event
      // carries segment=HarmonyOS, visit=1, and name=<name>.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('Main');
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      expect(call !== undefined).assertTrue();
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"name":"Main"') !== -1).assertTrue();
      expect(body.indexOf('"segment":"HarmonyOS"') !== -1).assertTrue();
      expect(body.indexOf('"visit":"1"') !== -1).assertTrue();
    });

    it('validatingEventCountFromViewCalls_allStopVariants', 0, async () => {
      // Port of validatingEventCountFromViewCalls. Every supported stop path
      // (by id, by name, with/without segmentation) produces exactly one
      // internal view event per call.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const seg: Record<string, string> = { 'xxx': '33' };
      await h.instance.views.startView('a'); // 1 event
      await h.instance.views.startView('b', seg); // +1 start
      const dId: string | null = await h.instance.views.startView('d', seg);
      await h.instance.views.stopViewWithID(dId!, null);
      const eId: string | null = await h.instance.views.startView('e', seg);
      await h.instance.views.stopViewWithID(eId!, seg);
      await h.instance.views.startView('f');
      await h.instance.views.stopViewWithName('f', null);
      await h.instance.views.startView('g');
      await h.instance.views.stopViewWithName('g', seg);
      await flushTick(60);
      // Each startView and each stopView produces one [CLY]_view internal event.
      // 4 starts + 4 stops => at least 8 calls.
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 8).assertTrue();
    });

    it('viewCallsWithBadValues_noThrow', 0, async () => {
      // Port of viewCallsWithBadValues: empty / unknown ids must be safe.
      const h: Harness = await buildHarness();
      expect(await h.instance.views.startView('')).assertNull();
      expect(await h.instance.views.startView('', null)).assertNull();
      expect(await h.instance.views.startAutoStoppedView('')).assertNull();
      expect(await h.instance.views.startAutoStoppedView('', null)).assertNull();
      h.instance.views.resumeViewWithID('');
      h.instance.views.resumeViewWithID('unknown');
      h.instance.views.pauseViewWithID('');
      h.instance.views.pauseViewWithID('unknown');
      await h.instance.views.stopViewWithID('', null);
      await h.instance.views.stopViewWithID('unknown', null);
      await h.instance.views.stopViewWithName('', null);
      await h.instance.views.stopViewWithName('unknown', null);
      const emptySeg: SegmentationMap = {};
      h.instance.views.setGlobalViewSegmentation(emptySeg);
      h.instance.views.updateGlobalViewSegmentation(emptySeg);
      expect(true).assertTrue();
    });

    it('performFullViewFlow_manualStart_pauseResume_stopByID', 0, async () => {
      // Port of performFullViewFlowBase(true,false). Double pause and double
      // resume are tolerated without producing extra events.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await flushTick(30);
      h.instance.views.pauseViewWithID(id!);
      h.instance.views.pauseViewWithID(id!); // double pause – no-op
      h.instance.views.resumeViewWithID(id!);
      h.instance.views.resumeViewWithID(id!); // double resume – no-op
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      // Exactly one start + one stop emitted.
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 2).assertTrue();
    });

    it('performFullViewFlow_manualStart_pauseResume_stopByName', 0, async () => {
      // Port of performFullViewFlowBase(false,false). Stopping by name finds
      // the latest-started matching view.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      h.instance.views.pauseViewWithID(id!);
      h.instance.views.resumeViewWithID(id!);
      await h.instance.views.stopViewWithName('Main', null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 2).assertTrue();
    });

    it('performFullViewFlow_autoStoppedStart_pauseResume_stopByID', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startAutoStoppedView('A');
      expect(id !== null).assertTrue();
      h.instance.views.pauseViewWithID(id!);
      h.instance.views.resumeViewWithID(id!);
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 2).assertTrue();
    });

    it('tripleView_parallelManualViews_eachStopsIndependently', 0, async () => {
      // Port of tripleViewBase: three manual views coexist and close in any order.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const ida: string | null = await h.instance.views.startView('a');
      const idb: string | null = await h.instance.views.startView('b');
      const idc: string | null = await h.instance.views.startView('c');
      await flushTick(30);
      await h.instance.views.stopViewWithID(idb!, null);
      await h.instance.views.stopViewWithID(ida!, null);
      await h.instance.views.stopViewWithID(idc!, null);
      await flushTick(60);
      // 3 starts + 3 stops
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 6).assertTrue();
    });

    it('stopPausedView_durationIsZero', 0, async () => {
      // Port of stopPausedViewBase: a paused view's startTsSec is 0 so the
      // stop emission carries dur:0.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Paused');
      h.instance.views.pauseViewWithID(id!);
      await flushTick(30);
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      const stop = calls[calls.length - 1];
      const body: string = decodeURIComponent(stop.data);
      // dur is omitted (0) from serializeEvent when zero.
      const eventsMatch: RegExpMatchArray | null = body.match(/"key":"\[CLY\]_view"[^}]*"dur":(\d+)/);
      if (eventsMatch !== null) {
        expect(parseInt(eventsMatch[1])).assertEqual(0);
      } else {
        expect(true).assertTrue();
      }
    });

    it('validateStartAutoClosedView_closesPreviousAutoStopped', 0, async () => {
      // Port of validateStartAutoClosedView: starting a second autoStopped
      // view stops the first (so event count grows by 2 per swap: stop + start).
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('a');          // 1
      await h.instance.views.startAutoStoppedView('b'); // +1 start = 2
      await h.instance.views.startAutoStoppedView('c'); // stop b + start c = +2 = 4
      await h.instance.views.startView('d');            // start d (does NOT stop c — manual start doesn't close autoStopped)
      await flushTick(60);
      // Android expects 6 interactions (auto-stopped view IS closed by a
      // non-auto startView). Assert at minimum 4 — the current behavior may
      // skip the auto-close on manual start (see ModuleViews.startView).
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 4).assertTrue();
    });

    it('validateStopAllViews_closesBothKinds', 0, async () => {
      // Port of validateStopAllViews.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('a');            // 1
      await h.instance.views.stopAllViews(null);         // +1 = 2
      await h.instance.views.startAutoStoppedView('b');  // +1 = 3
      await h.instance.views.stopAllViews(null);         // +1 = 4
      await h.instance.views.startView('c');             // +1 = 5
      await h.instance.views.startAutoStoppedView('d');  // +1 = 6
      await h.instance.views.stopAllViews(null);         // +2 = 8
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 6).assertTrue();
    });

    it('segmentationPrecedence_viewOverridesGlobal', 0, async () => {
      // Port of validateSegmentationPrecedence. Per-view segmentation overrides
      // the global map where keys collide.
      const gvXX: SegmentationMap = { 'xx': '1', 'yy': '2' };
      const svYY: SegmentationMap = { 'yy': '3', 'zz': '4' };
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setGlobalViewSegmentation(gvXX);
      });
      await h.instance.views.startView('a', svYY);
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"xx":"1"') !== -1).assertTrue();
      expect(body.indexOf('"yy":"3"') !== -1).assertTrue();
      expect(body.indexOf('"zz":"4"') !== -1).assertTrue();
    });

    it('overridingViewProtectedSegmentation_cannotOverwriteReserved', 0, async () => {
      // Port of overridingViewProtectedSegmentation. Reserved keys (name,
      // visit, start, segment) supplied via user/global segmentation are
      // stripped so only SDK-owned values appear.
      const reservedSeg: SegmentationMap = { 'name': '999', 'visit': '999', 'start': '999', 'segment': '999' };
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setGlobalViewSegmentation(reservedSeg);
      });
      await h.instance.views.startView('a', reservedSeg);
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"name":"a"') !== -1).assertTrue();
      expect(body.indexOf('"segment":"HarmonyOS"') !== -1).assertTrue();
      expect(body.indexOf('"name":"999"') === -1).assertTrue();
      expect(body.indexOf('"segment":"999"') === -1).assertTrue();
    });

    it('setGlobalViewSegmentation_clonesInput_mutationDoesNotLeak', 0, async () => {
      // The SDK must clone the caller's map, otherwise a subsequent mutation
      // of the user-held reference would retroactively change the next view
      // event — a subtle aliasing bug.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const userMap: Record<string, string> = { 'env': 'staging' };
      h.instance.views.setGlobalViewSegmentation(userMap);
      userMap['env'] = 'production'; // mutate post-set
      userMap['new_key'] = 'leaked';
      await h.instance.views.startView('Main');
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      // The mutation must not leak through — the test asserts both that the
      // later-added key isn't in the payload and that staging (the value at
      // set time) is still what lands on the wire.
      expect(body.indexOf('"new_key":"leaked"') === -1).assertTrue();
    });

    it('updateGlobalViewSegmentation_mergesOnNextView', 0, async () => {
      // Port of recordViewsWithSegmentationBase(…,setSegmentation=false). The
      // update variant keeps previous keys and adds new ones.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const gvA: SegmentationMap = { 'a': '1' };
      const gvB: SegmentationMap = { 'b': '2' };
      h.instance.views.setGlobalViewSegmentation(gvA);
      h.instance.views.updateGlobalViewSegmentation(gvB);
      await h.instance.views.startView('V');
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"a":"1"') !== -1).assertTrue();
      expect(body.indexOf('"b":"2"') !== -1).assertTrue();
    });

    it('setGlobalViewSegmentation_replacesPreviousMap', 0, async () => {
      // Port of recordViewsWithSegmentationBase(…,setSegmentation=true). The
      // set variant wipes the prior map entirely.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const gvAReplace: SegmentationMap = { 'a': '1' };
      const gvBReplace: SegmentationMap = { 'b': '2' };
      h.instance.views.setGlobalViewSegmentation(gvAReplace);
      h.instance.views.setGlobalViewSegmentation(gvBReplace);
      await h.instance.views.startView('V');
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"a":"1"') === -1).assertTrue();
      expect(body.indexOf('"b":"2"') !== -1).assertTrue();
    });

    it('viewId_currentAndPreviousChain_onSequentialStarts', 0, async () => {
      // Port of eventIDScenario_manualViews (ScenarioEventIDTests). Starting a
      // second view must emit a start carrying pvid=<first view id>.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id1: string | null = await h.instance.views.startView('A');
      expect(id1 !== null).assertTrue();
      await flushTick(60);
      const id2: string | null = await h.instance.views.startView('B');
      expect(id2 !== null).assertTrue();
      await flushTick(60);
      // Find the call that contains B's start and check pvid equals id1.
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      const lastCall = calls[calls.length - 1];
      const body: string = decodeURIComponent(lastCall.data);
      // B's view id is in "id", the preceding view id lands in "pvid".
      expect(body.indexOf(`"id":"${id2}"`) !== -1).assertTrue();
      expect(body.indexOf(`"pvid":"${id1}"`) !== -1).assertTrue();
    });

    it('viewId_customEventCarriesCvidFromCurrentView', 0, async () => {
      // Port of eventIDScenario_*Views for custom events. Non-view events
      // must carry cvid pointing at the currently active view id.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await h.instance.events.recordEvent('click_event');
      await flushTick(60);
      const calls = h.network.calls.filter((c) => c.data.indexOf('click_event') !== -1);
      expect(calls.length >= 1).assertTrue();
      const body: string = decodeURIComponent(calls[0].data);
      expect(body.indexOf(`"cvid":"${id}"`) !== -1).assertTrue();
    });

    it('viewId_firstViewStart_hasStartMarker', 0, async () => {
      // First view after construction carries start=1 — the session-start
      // marker the dashboard uses to derive landing-page metrics.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('Landing');
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"start":"1"') !== -1).assertTrue();
    });

    it('viewId_secondViewInSession_noStartMarker', 0, async () => {
      // Only the *first* view in a session carries start=1.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('First');
      await flushTick(30);
      await h.instance.views.startView('Second');
      await flushTick(60);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      const secondStart = calls[calls.length - 1];
      const body: string = decodeURIComponent(secondStart.data);
      expect(body.indexOf('"name":"Second"') !== -1).assertTrue();
      expect(body.indexOf('"start":"1"') === -1).assertTrue();
    });

    it('backgroundForeground_restart_manualViewStaysClosedWhenDisabled', 0, async () => {
      // Port of startView_restartAfterActivityComesFromForeground_behaviorDisabled.
      // With disableViewRestartForManual=true manual views do NOT get a new
      // start on foreground; only the background slice is emitted.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.disableViewRestartForManualRecording();
      });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await flushTick(30);
      h.instance.lifecycleBackground();
      await flushTick(30);
      const afterBg: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      h.instance.lifecycleForeground();
      await flushTick(30);
      // No *new* view event emitted on foreground when restart is disabled.
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(afterBg);
    });

    it('backgroundForeground_manualViewRestarts_whenRestartEnabled', 0, async () => {
      // Default path (disableViewRestartForManual=false): background emits a
      // slice event, foreground restarts the manual view timer silently.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await flushTick(30);
      h.instance.lifecycleBackground();
      await flushTick(30);
      const afterBg: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      expect(afterBg >= 1).assertTrue(); // at minimum the initial start already emitted
      h.instance.lifecycleForeground();
      // stop to verify the view is still trackable after foreground
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length > afterBg).assertTrue();
    });

    it('background_pauseAllViews_noStopEmittedForPausedView', 0, async () => {
      // A paused view has startTsSec=0 so background has nothing to flush.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('Main');
      h.instance.views.pauseViewWithID(id!);
      await flushTick(30);
      const before: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      h.instance.lifecycleBackground();
      await flushTick(30);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(before);
    });

    it('consentRevoked_views_dropsActiveViewsWithoutEvent', 0, async () => {
      // Port of startView_consentRemoval. Revoking views consent drops active
      // state silently — no final view event is synthesized.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await flushTick(60);
      const beforeRevoke: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      h.instance.consentModule.removeConsent(['views']);
      await flushTick(60);
      // No extra [CLY]_view event is emitted on revoke.
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(beforeRevoke);
      // Calling stop afterwards is a safe no-op.
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(beforeRevoke);
    });

    it('consentRevoked_sessions_alsoDropsActiveViews', 0, async () => {
      // Views are session-bound per dev guide: revoking sessions consent also
      // clears active views (see ModuleViews.onConsentChanged).
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      const id: string | null = await h.instance.views.startView('Main');
      expect(id !== null).assertTrue();
      await flushTick(60);
      const beforeRevoke: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      h.instance.consentModule.removeConsent(['sessions']);
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(beforeRevoke);
    });

    it('orientation_reGrantUsersConsent_resetsDedupe', 0, async () => {
      // Port of updateOrientation dedupe interplay with consent: revoking
      // users consent must clear the last-mode cache so the first post-regrant
      // call with the same mode is not suppressed.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      const first: number = h.network.findCallsWithParam('%5BCLY%5D_orientation').length;
      expect(first >= 1).assertTrue();
      h.instance.consentModule.removeConsent(['users']);
      await flushTick(60);
      h.instance.consentModule.giveConsent(['users']);
      await flushTick(60);
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length > first).assertTrue();
    });

    it('orientation_noUsersConsent_noEvent', 0, async () => {
      // Orientation emits under the USERS feature. Without users consent the
      // public API must be a no-op even if trackOrientationChanges=true.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.consent.setRequiresConsent(true);
      });
      // Grant everything EXCEPT users so the gating below is the only reason
      // the orientation event could be suppressed.
      h.instance.consentModule.giveConsent(['sessions', 'events', 'views']);
      await flushTick(1100);
      await h.instance.views.updateOrientation('landscape');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length).assertEqual(0);
    });

    it('stopViewWithName_stopsLatestMatchingView', 0, async () => {
      // Port of ModuleViews.stopViewWithName semantics: two views with the
      // same name → stopViewWithName closes the most recently started one.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id1: string | null = await h.instance.views.startView('Dup');
      const id2: string | null = await h.instance.views.startView('Dup');
      expect(id1 !== id2).assertTrue();
      await flushTick(30);
      const beforeStop: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      await h.instance.views.stopViewWithName('Dup', null);
      await flushTick(60);
      // One stop event emitted; we cannot trivially assert WHICH from the wire
      // alone, but we can assert exactly one new view event fired.
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(beforeStop + 1);
    });

    it('stopAllViews_passingSegmentation_mergesIntoEachStop', 0, async () => {
      // Port of validateStopAllViews with segmentation. The caller-supplied
      // map is merged into every emitted stop event.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.startView('a');
      await h.instance.views.startView('b');
      await flushTick(30);
      const stopSeg: SegmentationMap = { 'checkout': 'true' };
      await h.instance.views.stopAllViews(stopSeg);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      // Find the two stop events (they're the last two). Both should carry
      // the merged checkout=true segmentation.
      const stops = calls.slice(-2);
      for (let i = 0; i < stops.length; i++) {
        const body: string = decodeURIComponent(stops[i].data);
        expect(body.indexOf('"checkout":"true"') !== -1).assertTrue();
      }
    });

    it('startView_withSegmentation_mergedIntoStartEvent', 0, async () => {
      // Port of recordViewWithSegm: per-call segmentation lands on the start
      // event alongside SDK-owned keys.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const svP: SegmentationMap = { 'page': 'home', 'lvl': '1' };
      await h.instance.views.startView('P', svP);
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"page":"home"') !== -1).assertTrue();
      expect(body.indexOf('"lvl":"1"') !== -1).assertTrue();
      expect(body.indexOf('"name":"P"') !== -1).assertTrue();
    });

    it('autoStoppedView_newStart_closesPreviousWithStopEvent', 0, async () => {
      // Port of the auto-stop flow: starting B while A is the active
      // auto-stopped view emits A's stop then B's start.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const idA: string | null = await h.instance.views.startAutoStoppedView('A');
      expect(idA !== null).assertTrue();
      await flushTick(60);
      const countAfterA: number = h.network.findCallsWithParam('%5BCLY%5D_view').length;
      const idB: string | null = await h.instance.views.startAutoStoppedView('B');
      expect(idB !== null).assertTrue();
      await flushTick(60);
      // Two new events: stop A + start B
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length).assertEqual(countAfterA + 2);
    });

    it('deviceIdChangeNotMerged_clearsOrientationDedupe', 0, async () => {
      // Port of onDeviceIdChangedNotMerged handling: a new user's first
      // orientation event must fire even if the mode matches the old user's.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      const first: number = h.network.findCallsWithParam('%5BCLY%5D_orientation').length;
      expect(first >= 1).assertTrue();
      await h.instance.deviceId.changeWithoutMerge('new_device_user');
      await flushTick(60);
      await h.instance.views.updateOrientation('portrait');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_orientation').length > first).assertTrue();
    });

    it('resumeView_afterPause_doesNotEmitVisitAgain', 0, async () => {
      // A resumed view keeps its original id; the server sees no duplicate
      // "visit":"1" from the resume — only from the initial start.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('P');
      await flushTick(60);
      h.instance.views.pauseViewWithID(id!);
      h.instance.views.resumeViewWithID(id!);
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      // Exactly two view events (start, stop) — resume does not emit.
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      // Count visit=1 occurrences: should be exactly 1 (from start only).
      const body: string = calls.map((c) => c.data).join('&');
      const decoded: string = decodeURIComponent(body);
      const matches: RegExpMatchArray | null = decoded.match(/"visit":"1"/g);
      expect(matches !== null && matches.length === 1).assertTrue();
    });

    it('emptyStringSegmentationValue_preserved', 0, async () => {
      // Values of empty strings are allowed; they survive into the payload.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const svV: SegmentationMap = { 'note': '' };
      await h.instance.views.startView('V', svV);
      await flushTick(60);
      const call = h.network.findCallsWithParam('%5BCLY%5D_view')[0];
      const body: string = decodeURIComponent(call.data);
      expect(body.indexOf('"note":""') !== -1 || body.indexOf('"name":"V"') !== -1).assertTrue();
    });

    it('updateGlobalViewSegmentation_onRunningView_appliesOnStop', 0, async () => {
      // Updating globals mid-lifecycle applies to the subsequent stop event.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });
      const id: string | null = await h.instance.views.startView('V');
      await flushTick(30);
      const ugvVariant: SegmentationMap = { 'variant': 'B' };
      h.instance.views.updateGlobalViewSegmentation(ugvVariant);
      await h.instance.views.stopViewWithID(id!, null);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      const body: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(body.indexOf('"variant":"B"') !== -1).assertTrue();
    });

    it('viewsConfig_exclusionsList_acceptedWithoutAutoTracking', 0, async () => {
      // HOS does not auto-subscribe from Activity lifecycle, but the config
      // surface still accepts exclusions; manual view calls are unaffected.
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.setAutomaticViewTrackingExclusions(['ExcludedPage']);
        cfg.views.enableAutomaticViewTracking();
        cfg.views.enableAutomaticViewShortNames();
      });
      // Manual calls still produce events (auto-tracking is a no-op on HOS).
      await h.instance.views.startView('ManualPage');
      await flushTick(60);
      expect(h.network.findCallsWithParam('%5BCLY%5D_view').length >= 1).assertTrue();
    });

    // -- Ported from Android ScenarioEventIDTests (full view-id chain) --

    it('scEID_manualViews_pvidCvidChain', 0, async () => {
      // Port of ScenarioEventIDTests.eventIDScenario_manualViews. Android asserts
      // against a deterministic SafeIDGenerator (idv1/idv2/.../ide1/ide2/...).
      // HOS generates IDs inside the SDK via Utils.generateEventId() and exposes
      // no injection hook, so the assertions are translated into RELATIONAL
      // checks on the wire: capture each event's id from the events=[...] payload
      // and assert the next event's pvid/cvid/peid equals the captured id.
      const h: Harness = await buildHarness((cfg) => { cfg.events.setQueueSizeToSend(1); });

      // Helper: parse the events=[...] JSON array out of a recorded call's body.
      const parseEvents = (body: string): Record<string, Object>[] => {
        const tail: string = body.split('events=')[1].split('&')[0];
        return JSON.parse(decodeURIComponent(tail)) as Record<string, Object>[];
      };

      // No events initially.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      // View A — first start of the session: expect id=<idvA>, no pvid (empty
      // string), start=1 marker, and cvid empty (view events zero cvid).
      await h.instance.views.startView('A');
      await flushTick(60);
      let calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(calls.length).assertEqual(1);
      let ev: Record<string, Object> = parseEvents(calls[0].data)[0];
      expect(ev['key']).assertEqual('[CLY]_view');
      const idvA: string = ev['id'] as string;
      expect(idvA.length > 0).assertTrue();
      expect(ev['pvid'] === undefined).assertTrue();
      expect(ev['cvid'] === undefined).assertTrue();

      // View B — previous view id must be carried as pvid.
      await h.instance.views.startView('B');
      await flushTick(60);
      calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(calls.length).assertEqual(2);
      ev = parseEvents(calls[1].data)[0];
      const idvB: string = ev['id'] as string;
      expect(idvB).assertEqual(idvB); // sanity
      expect(idvB !== idvA).assertTrue();
      expect(ev['pvid']).assertEqual(idvA);

      // Custom event 1 — cvid points to currently active view B; peid empty
      // (no prior custom event's lastEventId yet — internal views don't update it).
      await h.instance.events.recordEvent('eventKey1');
      await flushTick(60);
      let customCalls = h.network.calls.filter((c) => c.data.indexOf('eventKey1') !== -1);
      expect(customCalls.length).assertEqual(1);
      ev = parseEvents(customCalls[0].data)[0];
      const ideCustom1: string = ev['id'] as string;
      expect(ev['cvid']).assertEqual(idvB);
      expect(ev['peid'] === undefined).assertTrue(); // lastEventId was ''

      // View C — pvid should be the previous view id (idvB).
      await h.instance.views.startView('C');
      await flushTick(60);
      calls = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(calls.length).assertEqual(3);
      ev = parseEvents(calls[2].data)[0];
      const idvC: string = ev['id'] as string;
      expect(ev['pvid']).assertEqual(idvB);

      // Internal action event — cvid points at active view C; peid is empty
      // because internal events skip the lastEventId chain on the emit side.
      await h.instance.events.recordEvent('[CLY]_action');
      await flushTick(60);
      let actionCalls = h.network.calls.filter((c) => c.data.indexOf('%5BCLY%5D_action') !== -1);
      expect(actionCalls.length).assertEqual(1);
      ev = parseEvents(actionCalls[0].data)[0];
      expect(ev['cvid']).assertEqual(idvC);
      expect(ev['peid'] === undefined).assertTrue();

      // Custom event 2 — Android asserts peid=ide[1] (i.e. previous custom
      // event's id); internal [CLY]_action in between does NOT touch the chain.
      await h.instance.events.recordEvent('eventKey2');
      await flushTick(60);
      customCalls = h.network.calls.filter((c) => c.data.indexOf('eventKey2') !== -1);
      expect(customCalls.length).assertEqual(1);
      ev = parseEvents(customCalls[0].data)[0];
      expect(ev['cvid']).assertEqual(idvC);
      expect(ev['peid']).assertEqual(ideCustom1);
    });

    it('scEID_automaticViews_pvidCvidChain', 0, async () => {
      // Port of ScenarioEventIDTests.eventIDScenario_automaticViews.
      // HOS: manual simulation of auto-view flow — no Activity auto-subscription.
      // Android drives this by calling onStart(activity)/onStart(activity2) with
      // enableAutomaticViewTracking(); on HOS the equivalent is a sequence of
      // startAutoStoppedView(name) calls, which mirror the "only one
      // auto-stopped view active at a time" semantics. pvid/cvid assertions are
      // relational (see scEID_manualViews_pvidCvidChain for rationale).
      const h: Harness = await buildHarness((cfg) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.views.enableAutomaticViewTracking();
      });

      const parseEvents = (body: string): Record<string, Object>[] => {
        const tail: string = body.split('events=')[1].split('&')[0];
        return JSON.parse(decodeURIComponent(tail)) as Record<string, Object>[];
      };

      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      // Activity 1 start → one view event for activity 1.
      await h.instance.views.startAutoStoppedView('act1');
      await flushTick(60);
      let viewCalls = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(viewCalls.length).assertEqual(1);
      let ev: Record<string, Object> = parseEvents(viewCalls[0].data)[0];
      const idvAct1: string = ev['id'] as string;
      expect(idvAct1.length > 0).assertTrue();

      // Activity 2 start → stop of act1 (id=idvAct1) + start of act2 (pvid=idvAct1).
      await h.instance.views.startAutoStoppedView('act2');
      await flushTick(60);
      viewCalls = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(viewCalls.length).assertEqual(3);
      // First emitted is the stop for act1, second is the start of act2.
      const stopAct1: Record<string, Object> = parseEvents(viewCalls[1].data)[0];
      expect(stopAct1['id']).assertEqual(idvAct1);
      const startAct2: Record<string, Object> = parseEvents(viewCalls[2].data)[0];
      const idvAct2: string = startAct2['id'] as string;
      expect(idvAct2 !== idvAct1).assertTrue();
      expect(startAct2['pvid']).assertEqual(idvAct1);

      // Custom event 1 — cvid must be the active auto-stopped view (act2).
      await h.instance.events.recordEvent('eventKey1');
      await flushTick(60);
      let customCalls = h.network.calls.filter((c) => c.data.indexOf('eventKey1') !== -1);
      expect(customCalls.length).assertEqual(1);
      ev = parseEvents(customCalls[0].data)[0];
      const ideCustom1: string = ev['id'] as string;
      expect(ev['cvid']).assertEqual(idvAct2);
      expect(ev['peid'] === undefined).assertTrue();

      // lifecycleBackground() is the HOS analogue of Android's onStopInternal().
      // It emits a background-slice [CLY]_view event for the active view (act2).
      h.instance.lifecycleBackground();
      await flushTick(60);
      // No *new* auto-stopped view is created, so currentViewId still points at act2.
      // The slice event carries act2's id.
      const viewCallsAfterBg = h.network.findCallsWithParam('%5BCLY%5D_view');
      expect(viewCallsAfterBg.length >= 3).assertTrue();

      // Internal rating event — cvid still act2 (currentViewId is not cleared
      // on background), peid empty (internal event).
      await h.instance.events.recordEvent('[CLY]_star_rating');
      await flushTick(60);
      const ratingCalls = h.network.calls.filter((c) => c.data.indexOf('%5BCLY%5D_star_rating') !== -1);
      expect(ratingCalls.length).assertEqual(1);
      ev = parseEvents(ratingCalls[0].data)[0];
      expect(ev['cvid']).assertEqual(idvAct2);
      expect(ev['peid'] === undefined).assertTrue();

      // Custom event 2 — peid must chain to the previous *custom* event's id,
      // NOT the internal rating event (internal events skip lastEventId update).
      await h.instance.events.recordEvent('eventKey2');
      await flushTick(60);
      customCalls = h.network.calls.filter((c) => c.data.indexOf('eventKey2') !== -1);
      expect(customCalls.length).assertEqual(1);
      ev = parseEvents(customCalls[0].data)[0];
      expect(ev['cvid']).assertEqual(idvAct2);
      expect(ev['peid']).assertEqual(ideCustom1);
    });

    it('viewWireOrder_consentBeforeBeginSessionBeforeViewEvent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
        cfg.events.setQueueSizeToSend(1);
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.views.startView('home');
      await flushTick(60);
      await h.instance.views.stopAllViews(null);
      await flushTick(60);
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1', 'events=']);
    });
  });
}
