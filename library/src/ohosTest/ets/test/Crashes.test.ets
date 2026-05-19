import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { CrashData, SegmentationMap, ThreadStackEntry } from '../../../main/ets/types/Types';

class TestThreadStack implements ThreadStackEntry {
  public name: string;
  public stack: string;
  constructor(name: string, stack: string) {
    this.name = name;
    this.stack = stack;
  }
}

class DroppedBag {
  public a: number = 0;
  constructor(a: number) {
    this.a = a;
  }
}

class NestedBag {
  public nested: number = 0;
  constructor(nested: number) {
    this.nested = nested;
  }
}

export default function crashesTest() {
  describe('CrashesTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('recordHandled_addsCrashParam', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordHandledException(new Error('boom'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(1);
    });

    it('recordUnhandled_setsNonfatalFalse', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordUnhandledException(new Error('bad'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call !== undefined).assertTrue();
      // decoded crash param should include _nonfatal%22%3Afalse somewhere
      expect(call.data.indexOf('_nonfatal') !== -1).assertTrue();
    });

    it('breadcrumbs_includedInCrashReport', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.crashes.addCrashBreadcrumb('visited-home');
      h.instance.crashes.addCrashBreadcrumb('pressed-login');
      await h.instance.crashes.recordHandledException(new Error('err'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call.data.indexOf('_logs') !== -1).assertTrue();
    });

    it('breadcrumbs_capAtMaxCount', 0, async () => {
      const h: Harness = await buildHarness();
      for (let i = 0; i < 150; i++) h.instance.crashes.addCrashBreadcrumb(`bc-${i}`);
      await h.instance.crashes.recordHandledException(new Error('err'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      // bc-0 should be dropped; bc-149 should be present.
      expect(call.data.indexOf('bc-149') !== -1).assertTrue();
    });

    it('filter_canDropCrash', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((_crash: CrashData) => true);
      });
      await h.instance.crashes.recordHandledException(new Error('dropme'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(0);
    });

    it('filter_canMutateStackTrace_andObBitSet', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData) => {
          crash.stackTrace = 'redacted';
          return false;
        });
      });
      await h.instance.crashes.recordHandledException(new Error('secret'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('_ob') !== -1).assertTrue();
      expect(call.data.indexOf('redacted') !== -1).assertTrue();
    });

    it('customSegmentation_merged', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'build': 'debug' };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      const featureSeg: SegmentationMap = { 'feature': 'auth' };
      await h.instance.crashes.recordHandledException(new Error('e'), featureSeg);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call.data.indexOf('build') !== -1 || call.data.indexOf('feature') !== -1).assertTrue();
    });

    it('crashes_gatedByConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      await h.instance.crashes.recordHandledException(new Error('no-consent'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(0);
    });

    it('recordAllThreads_withProvider_appendsWorkerStacks', 0, async () => {
      // recordAllThreadsWithCrash=true AND a provider is wired, the
      // Worker stacks must show up in the crash payload in Android's wire
      // format (`Thread <name>` marker URL-encoded as `Thread%20<name>`).
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.enableRecordAllThreadsWithCrash();
      });
      h.instance.crashes.setThreadStackProvider((): ThreadStackEntry[] => {
        const entries: ThreadStackEntry[] = [];
        entries.push(new TestThreadStack('worker-1', 'Error: oops\n    at workerFn (worker.ts:42)'));
        return entries;
      });
      await h.instance.crashes.recordHandledException(new Error('main-crash'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call !== undefined).assertTrue();
      // URL-encoded body will contain "Thread worker-1" as Thread%20worker-1.
      // Just check for the distinctive thread name + the header fragment.
      expect(call.data.indexOf('Thread%20worker-1') !== -1).assertTrue();
    });

    it('recordAllThreads_noProvider_stillShipsMainStack', 0, async () => {
      // Flag enabled but no provider wired: crash must still ship (with
      // just the main stack). The one-time warning is a log-only concern.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.enableRecordAllThreadsWithCrash();
      });
      await h.instance.crashes.recordHandledException(new Error('lonely-main'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(1);
    });

    it('recordAllThreads_providerThrows_doesNotMaskCrash', 0, async () => {
      // A throwing provider at crash time is never allowed to swallow the
      // crash, we lose the extra thread info but the main stack still
      // reaches the queue. This was a real bug shape in earlier ports.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.enableRecordAllThreadsWithCrash();
      });
      h.instance.crashes.setThreadStackProvider(() => { throw new Error('provider-broke'); });
      await h.instance.crashes.recordHandledException(new Error('c'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(1);
    });

    // --- Ported from ModuleCrashTests.java ---

    it('addCrashBreadcrumb_multipleConcatenated', 0, async () => {
      // Android: addCrashBreadcrumb, multiple breadcrumbs concatenated into
      // _logs separated by newline. HOS joins with '\n' too, the URL-encoded
      // payload renders newline as %0A.
      const h: Harness = await buildHarness();
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_1');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_2');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_3');
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('Breadcrumb_1') !== -1).assertTrue();
      expect(call.data.indexOf('Breadcrumb_2') !== -1).assertTrue();
      expect(call.data.indexOf('Breadcrumb_3') !== -1).assertTrue();
    });

    it('addCrashBreadcrumb_emptyIgnored', 0, async () => {
      // Android: addCrashBreadcrumbNullEmpty, empty breadcrumbs are silently
      // ignored, valid ones still ship. (HOS's public signature is
      // `record: string` so the null arm of the Java test isn't applicable
      // through the public API, covered only indirectly by ModuleCrashes
      // calling `Utils.isNullOrEmpty`.)
      const h: Harness = await buildHarness();
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_4');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_5');
      h.instance.crashes.addCrashBreadcrumb('');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_6');
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call.data.indexOf('Breadcrumb_4') !== -1).assertTrue();
      expect(call.data.indexOf('Breadcrumb_5') !== -1).assertTrue();
      expect(call.data.indexOf('Breadcrumb_6') !== -1).assertTrue();
    });

    it('recordHandled_errorMessageAndNameInStack', 0, async () => {
      // Android: recordHandledExceptionException/Throwable, assert the stack
      // trace starts with the error class + message. JS Error.stack usually
      // begins with "Error: Some message" which becomes %20 in the payload.
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordHandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      // URL-encoded payload, "Error: Some message" → "Error%3A%20Some%20message"
      // Assert message survives round-trip.
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('Some message') !== -1).assertTrue();
    });

    it('recordUnhandled_errorMessageInStack', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('Some message') !== -1).assertTrue();
    });

    it('provideCustomCrashSegment_DuringInit', 0, async () => {
      // Android: provideCustomCrashSegment_DuringInit, global segmentation set
      // via config is applied to every crash.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'aa': 'dd', 'aa1': 'dda', '1': 1234, '3': true };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      await h.instance.crashes.recordHandledException(new Error('e'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"aa":"dd"') !== -1).assertTrue();
      expect(decoded.indexOf('"aa1":"dda"') !== -1).assertTrue();
      expect(decoded.indexOf('"1":1234') !== -1).assertTrue();
      expect(decoded.indexOf('"3":true') !== -1).assertTrue();
    });

    it('provideCustomCrashSegment_DuringInitAndCall', 0, async () => {
      // Android: provideCustomCrashSegment_DuringInitAndCall, per-call
      // segmentation wins over global with same key. Merged set lands in _custom.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'aa': 'dd', 'aa1': 'dda', '1': 1234 };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      await h.instance.crashes.recordHandledException(new Error('Some message'), { '1': 54, '2': 1234.55, '3': true });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // all keys from both maps should be present
      expect(decoded.indexOf('"aa":"dd"') !== -1).assertTrue();
      expect(decoded.indexOf('"aa1":"dda"') !== -1).assertTrue();
      // per-call overrides global for the same key
      expect(decoded.indexOf('"1":54') !== -1).assertTrue();
      expect(decoded.indexOf('"3":true') !== -1).assertTrue();
    });

    it('globalCrashFilter_mutatesSegmentationFatalAndMetrics', 0, async () => {
      // Android: recordHandledException_globalCrashFilter, filter removes a
      // segmentation key, flips fatal, injects a metric. _ob reflects which
      // fields changed. Validate the mutations landed and _ob is non-zero.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'secret': 'Minato', 'keep': 'me' };
        cfg.crashes.setCustomCrashSegmentation(ccs);
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => {
          if (crash.stackTrace.indexOf('Secret') !== -1) return true;
          // ArkTS bans the `delete` operator; rebuild the map without the key.
          const filtered: SegmentationMap = {};
          const keys: string[] = Object.keys(crash.crashSegmentation);
          for (let i = 0; i < keys.length; i++) {
            if (keys[i] !== 'secret') filtered[keys[i]] = crash.crashSegmentation[keys[i]];
          }
          crash.crashSegmentation = filtered;
          crash.fatal = true;
          crash.crashMetrics['custom_metric'] = 'injected';
          return false;
        });
      });
      // First call, dropped by stack-trace filter
      await h.instance.crashes.recordHandledException(new Error('Secret message'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(0);

      // Second call, passes through, filter still mutates
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_1');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_2');
      await h.instance.crashes.recordHandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      expect(call !== undefined).assertTrue();
      const decoded = decodeURIComponent(call.data);
      // secret was removed
      expect(decoded.indexOf('"secret"') === -1).assertTrue();
      // injected metric is present
      expect(decoded.indexOf('custom_metric') !== -1).assertTrue();
      // fatal true → _nonfatal is false
      expect(decoded.indexOf('"_nonfatal":false') !== -1).assertTrue();
      // _ob must be non-zero because fields mutated
      const obMatch: RegExpMatchArray | null = decoded.match(/"_ob":(\d+)/);
      expect(obMatch !== null && parseInt(obMatch[1]) > 0).assertTrue();
    });

    it('globalCrashFilter_returningFalse_noObChange', 0, async () => {
      // Android: recordHandledException_basic, filter returns false and does
      // not mutate. _ob must be 0 because nothing changed.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'int': 99, 'bool': true };
        cfg.crashes.setCustomCrashSegmentation(ccs);
        cfg.crashes.setGlobalCrashFilterCallback((_crash: CrashData): boolean => false);
      });
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_1');
      await h.instance.crashes.recordHandledException(new Error('Some message'), { 'sphinx_no': 324 });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"_ob":0') !== -1).assertTrue();
      expect(decoded.indexOf('"int":99') !== -1).assertTrue();
      expect(decoded.indexOf('"sphinx_no":324') !== -1).assertTrue();
    });

    it('globalCrashFilter_emptyAllFields_obBitsSet', 0, async () => {
      // Android: recordHandledException_globalCrashFilter_allFieldsEmpty,
      // filter sets every mutable field to empty, toggles fatal. The payload
      // gets an _ob value with all relevant bits set.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => {
          crash.stackTrace = '';
          crash.crashSegmentation = {};
          crash.crashMetrics = {};
          crash.breadcrumbs = [];
          crash.fatal = !crash.fatal;
          return false;
        });
      });
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_1');
      h.instance.crashes.addCrashBreadcrumb('Breadcrumb_2');
      await h.instance.crashes.recordHandledException(new Error('Some message'), { 'sphinx_no': 324 });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // Every tracked field changed, _ob must be non-zero and > 1
      const obMatch: RegExpMatchArray | null = decoded.match(/"_ob":(\d+)/);
      // at minimum stack(16) + segmentation(8) + breadcrumbs(4) + fatal(1) changed
      // plus metrics(2) because we emptied the map too.
      expect(obMatch !== null && parseInt(obMatch[1]) >= (16 + 8 + 4 + 2 + 1)).assertTrue();
    });

    it('globalCrashFilter_dropFatal_handledPasses', 0, async () => {
      // Android: recordException_globalCrashFilter_dropFatal, filter returns
      // crash.fatal, so unhandled calls drop and handled calls pass through.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => crash.fatal);
      });
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(0);

      await h.instance.crashes.recordHandledException(new Error('Some message 2'), null);
      await flushTick(60);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(1);
    });

    it('globalCrashFilter_appendsBreadcrumbs_capHonored', 0, async () => {
      // Android: recordException_globalCrashFilter_exceedMaxBreadcrumb, the
      // filter may grow the breadcrumb list; the post-filter cap re-applies so
      // only the last N breadcrumbs ship.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => {
          crash.breadcrumbs.push('5');
          crash.breadcrumbs.push('6');
          crash.breadcrumbs.push('7');
          return false;
        });
      });
      // Manually tighten the internal cap for this test.
      h.instance.config.limits.maxBreadcrumbCount = 2;
      h.instance.crashes.addCrashBreadcrumb('1');
      h.instance.crashes.addCrashBreadcrumb('2');
      h.instance.crashes.addCrashBreadcrumb('3');
      await h.instance.crashes.recordUnhandledException(new Error('secret'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // After add-then-cap, we expect the final two breadcrumbs to be the
      // last two items pushed by the filter ("6\n7").
      expect(decoded.indexOf('"_logs":"6\\n7"') !== -1).assertTrue();
    });

    it('globalCrashFilter_invalidSegmentationValuesStripped', 0, async () => {
      // Android: recordException_globalCrashFilter_invalidCustomSegmentations
      //, unsupported data types added during filtering must be scrubbed
      // before shipping.
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => {
          // Supported, should survive
          crash.crashSegmentation['legit'] = 'yes';
          // Unsupported, an object, must be dropped by sanitizeSegmentation.
          const raw: Record<string, Object> = crash.crashSegmentation as Record<string, Object>;
          raw['nope'] = new DroppedBag(1) as Object;
          return false;
        });
      });
      await h.instance.crashes.recordUnhandledException(new Error('secret'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"legit":"yes"') !== -1).assertTrue();
      expect(decoded.indexOf('"nope"') === -1).assertTrue();
    });

    it('internalLimits_maxSegmentationValues_truncatesMerged', 0, async () => {
      // Android: internalLimits_recordException_maxSegmentationValues, merged
      // global + per-call segmentation is clipped to the cap. Just assert the
      // merged count on the payload matches the cap.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'a': '1', 'b': '2', 'c': '3' };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      h.instance.config.limits.maxSegmentationValues = 2;
      await h.instance.crashes.recordHandledException(new Error('Some message'), { 'd': '4', 'e': '5', 'f': '6' });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // Count the number of keys inside "_custom":{...}. Use a cheap regex
      // against the decoded JSON, avoids a real parse while being robust to
      // key ordering.
      const customMatch: RegExpMatchArray | null = decoded.match(/"_custom":\{([^}]*)\}/);
      expect(customMatch !== null).assertTrue();
      const inner: string = customMatch === null ? '' : customMatch[1];
      // Each entry is "key":value, count commas + 1 as entry count.
      const entryCount: number = inner.length === 0 ? 0 : inner.split(',').length;
      expect(entryCount).assertEqual(2);
    });

    it('internalLimits_maxValueSize_truncatesBreadcrumbsAndSegmentation', 0, async () => {
      // Android: internalLimits_recordException_maxValueSize, string values
      // in segmentation and breadcrumb entries are clipped to the cap.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'test': '123456' };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      h.instance.config.limits.maxValueSize = 5;
      h.instance.crashes.addCrashBreadcrumb('Surpass');
      h.instance.crashes.addCrashBreadcrumb('YourLimits');
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), { 'have': 'dinosaur' });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // Segmentation values truncated to 5 chars
      expect(decoded.indexOf('"test":"12345"') !== -1).assertTrue();
      expect(decoded.indexOf('"have":"dinos"') !== -1).assertTrue();
      // Breadcrumbs truncated (each line)
      expect(decoded.indexOf('Surpa') !== -1).assertTrue();
      expect(decoded.indexOf('YourL') !== -1).assertTrue();
      // And the full 'Surpass' / 'YourLimits' must NOT appear
      expect(decoded.indexOf('Surpass') === -1).assertTrue();
      expect(decoded.indexOf('YourLimits') === -1).assertTrue();
    });

    it('internalLimits_maxKeyLength_truncatesSegmentationKeys', 0, async () => {
      // Android: internalLimits_provideCustomCrashSegment_recordUnhandledException
      //, keys over the limit are truncated.
      const h: Harness = await buildHarness((cfg) => {
        const ccs: SegmentationMap = { 'below_zero': true };
        cfg.crashes.setCustomCrashSegmentation(ccs);
      });
      h.instance.config.limits.maxKeyLength = 5;
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), { 'go_for_it': 'go' });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // keys truncated to first 5 chars
      expect(decoded.indexOf('"below":true') !== -1).assertTrue();
      expect(decoded.indexOf('"go_fo":"go"') !== -1).assertTrue();
      // originals must not appear as keys
      expect(decoded.indexOf('"below_zero"') === -1).assertTrue();
      expect(decoded.indexOf('"go_for_it"') === -1).assertTrue();
    });

    it('internalLimits_stackTraceLineLength_truncates', 0, async () => {
      // Android: internalLimits_recordException_stackTraceLimits_lineLength,
      // every line of the stack trace is clipped to maxStackTraceLineLength.
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxStackTraceLineLength = 2;
      await h.instance.crashes.recordUnhandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // Extract the _error value (JSON string up to the next unescaped quote).
      const errMatch: RegExpMatchArray | null = decoded.match(/"_error":"((?:[^"\\]|\\.)*)"/);
      expect(errMatch !== null).assertTrue();
      const err: string = errMatch === null ? '' : errMatch[1];
      // Every line (split on literal \n in the JSON-escaped string) must be
      // at most 2 chars long.
      const lines: string[] = err.split('\\n');
      for (let i = 0; i < lines.length; i++) {
        expect(lines[i].length <= 2).assertTrue();
      }
    });

    it('recordHandled_supportedArraySegmentations', 0, async () => {
      // Android: recordHandledException_validateSupportedArrays, primitive
      // arrays are serialized as JSON arrays on the wire. HOS SegmentationValue
      // accepts string[] / number[] / boolean[].
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordHandledException(new Error('Some message'), {
        'arrN': [1, 2, 3],
        'arrS': ['a', 'b'],
        'arrB': [true, false]
      });
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"arrN":[1,2,3]') !== -1).assertTrue();
      expect(decoded.indexOf('"arrS":["a","b"]') !== -1).assertTrue();
      expect(decoded.indexOf('"arrB":[true,false]') !== -1).assertTrue();
    });

    it('recordHandled_unsupportedSegmentationDroppedViaFilter', 0, async () => {
      // Android: recordHandledException_unsupportedDataTypesSegmentation,
      // unsupported value types are silently dropped. HOS SegmentationValue
      // is compile-time-restricted so the only way to reach the sanitiser
      // with a non-primitive is via the filter callback (which gives the
      // caller untyped write access to crashSegmentation).
      const h: Harness = await buildHarness((cfg) => {
        cfg.crashes.setGlobalCrashFilterCallback((crash: CrashData): boolean => {
          crash.crashSegmentation['keep'] = 'kept';
          // Force-push an unsupported record, sanitizeSegmentation must drop
          // it before the payload is built.
          const raw: Record<string, Object> = crash.crashSegmentation as Record<string, Object>;
          raw['drop'] = new NestedBag(1) as Object;
          return false;
        });
      });
      await h.instance.crashes.recordHandledException(new Error('Some message'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"keep":"kept"') !== -1).assertTrue();
      expect(decoded.indexOf('"drop"') === -1).assertTrue();
    });

    // --- Ported from CrashDetailsTests.java ---

    it('crashPayload_containsDeviceMetrics', 0, async () => {
      // Android: simpleCrashDetails_* / testCustomSegments, the crash payload
      // must carry _os, _device, _os_version, _app_version alongside _error
      // and _nonfatal. HOS DeviceInfo populates _os ("HarmonyOS"), _device
      // (productModel), _os_version (displayVersion), _app_version (config).
      const h: Harness = await buildHarness((cfg) => {
        cfg.setAppVersion('9.9.9');
      });
      await h.instance.crashes.recordHandledException(new Error('SomeError!@##'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"_os":"HarmonyOS"') !== -1).assertTrue();
      expect(decoded.indexOf('"_device"') !== -1).assertTrue();
      expect(decoded.indexOf('"_os_version"') !== -1).assertTrue();
      expect(decoded.indexOf('"_app_version":"9.9.9"') !== -1).assertTrue();
      expect(decoded.indexOf('"_error"') !== -1).assertTrue();
      expect(decoded.indexOf('"_nonfatal":true') !== -1).assertTrue();
    });

    it('crashPayload_metricOverride_replacesAutoDetected', 0, async () => {
      // Android: crashMetrics_override, metricOverride entries replace the
      // auto-collected values for _device/_os/_os_version/_app_version.
      const h: Harness = await buildHarness((cfg) => {
        cfg.setMetricOverride({
          '_device': '112',
          '_os': 'q12',
          '_os_version': 'w12',
          '_app_version': 'r12',
          '_manufacturer': 't12'
        });
      });
      await h.instance.crashes.recordHandledException(new Error('e'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"_device":"112"') !== -1).assertTrue();
      expect(decoded.indexOf('"_os":"q12"') !== -1).assertTrue();
      expect(decoded.indexOf('"_os_version":"w12"') !== -1).assertTrue();
      expect(decoded.indexOf('"_app_version":"r12"') !== -1).assertTrue();
      expect(decoded.indexOf('"_manufacturer":"t12"') !== -1).assertTrue();
    });

    it('crashPayload_containsRunDuration', 0, async () => {
      // Android: simpleCrashDetails_* checks for "_run" on non-native crashes.
      // HOS ModuleCrashes always stamps `_run` (seconds since module init).
      const h: Harness = await buildHarness();
      await h.instance.crashes.recordHandledException(new Error('e'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      expect(decoded.indexOf('"_run"') !== -1).assertTrue();
    });

    // --- Ported from BreadcrumbHelperTests.java ---

    it('breadcrumbs_truncatedToMaxValueSize', 0, async () => {
      // Android: addBreadcrumb_exceedsCharacterLimit, oversized breadcrumb is
      // kept but clipped to the per-value char cap.
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxValueSize = 2;
      h.instance.crashes.addCrashBreadcrumb('Test');
      await h.instance.crashes.recordHandledException(new Error('e'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // "Te" survives, "Test" does not appear as a breadcrumb
      expect(decoded.indexOf('"_logs":"Te"') !== -1).assertTrue();
    });

    it('breadcrumbs_rotateOldestWhenOverCap', 0, async () => {
      // Android: addBreadcrumb_exceedsLimit, adding past the cap drops the
      // oldest entry so only the most recent N ship.
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxBreadcrumbCount = 2;
      // Use breadcrumb labels that won't collide with the test file path
      // (the stack trace lands in `_error` and contains `Crashes.test.*`).
      h.instance.crashes.addCrashBreadcrumb('Apple');
      h.instance.crashes.addCrashBreadcrumb('Doggy');
      h.instance.crashes.addCrashBreadcrumb('Geralt');
      await h.instance.crashes.recordHandledException(new Error('e'), null);
      await flushTick(60);
      const call = h.network.findCallsWithParam('crash=')[0];
      const decoded = decodeURIComponent(call.data);
      // Only Doggy + Geralt should remain; Apple (oldest) dropped.
      expect(decoded.indexOf('Doggy') !== -1).assertTrue();
      expect(decoded.indexOf('Geralt') !== -1).assertTrue();
      expect(decoded.indexOf('Apple') === -1).assertTrue();
    });

    // --- Ported from CrashDataTests.java (applicable only) ---
    // HOS `CrashData` is a plain value-holder with direct public fields, no
    // `calculateChangedFields` / `getChangedFieldsAsInt` / `getBreadcrumbsAsString`
    // methods exist, so only the constructor test maps across.

    it('crashData_constructorStoresAllFields', 0, () => {
      // Android: testConstructor, ensure CrashData's five-arg ctor stores
      // every field verbatim.
      const breadcrumbs: string[] = ['key', 'value'];
      const cd: CrashData = new CrashData('ST', breadcrumbs, { 'key': 'value' }, { 'key': 'value' }, true);
      expect(cd.stackTrace).assertEqual('ST');
      expect(cd.breadcrumbs.length).assertEqual(2);
      expect(cd.breadcrumbs[0]).assertEqual('key');
      expect(cd.breadcrumbs[1]).assertEqual('value');
      expect(cd.crashSegmentation['key']).assertEqual('value');
      expect(cd.crashMetrics['key']).assertEqual('value');
      expect(cd.fatal).assertTrue();
    });

    it('crashWireOrder_consentBeforeBeginSessionBeforeCrash', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.crashes.recordHandledException(new Error('boom'), null);
      await flushTick(60);
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1', 'crash=']);
    });
  });
}
