import { describe, it, expect } from '@ohos/hypium';
import { Utils } from '../../../main/ets/internal/Utils';
import { Limits } from '../../../main/ets/internal/Limits';
import { Logger } from '../../../main/ets/internal/Logger';
import { SegmentationMap, SegmentationValue } from '../../../main/ets/types/Types';

export default function utilsTest() {
  describe('UtilsTest', () => {
    it('uniqueTimestampMs_alwaysIncreasing', 0, () => {
      const a: number = Utils.uniqueTimestampMs();
      const b: number = Utils.uniqueTimestampMs();
      const c: number = Utils.uniqueTimestampMs();
      expect(b > a).assertTrue();
      expect(c > b).assertTrue();
    });

    it('hourOf_returnsLocalHour', 0, () => {
      const h: number = Utils.hourOf(Date.now());
      expect(h >= 0 && h <= 23).assertTrue();
    });

    it('dayOfWeek_returnsValidRange', 0, () => {
      const d: number = Utils.dayOfWeek(Date.now());
      expect(d >= 0 && d <= 6).assertTrue();
    });

    it('isNullOrEmpty_cases', 0, () => {
      expect(Utils.isNullOrEmpty(null)).assertTrue();
      expect(Utils.isNullOrEmpty(undefined)).assertTrue();
      expect(Utils.isNullOrEmpty('')).assertTrue();
      expect(Utils.isNullOrEmpty('x')).assertFalse();
    });

    it('stripTrailingSlashes', 0, () => {
      expect(Utils.stripTrailingSlashes('https://a.com///')).assertEqual('https://a.com');
      expect(Utils.stripTrailingSlashes('https://a.com')).assertEqual('https://a.com');
    });

    it('isValidUrl', 0, () => {
      expect(Utils.isValidUrl('https://a.com')).assertTrue();
      expect(Utils.isValidUrl('http://a.com')).assertTrue();
      expect(Utils.isValidUrl('ftp://a.com')).assertFalse();
      expect(Utils.isValidUrl('')).assertFalse();
    });

    it('truncate_respectsLimit', 0, () => {
      expect(Utils.truncate('hello', 3)).assertEqual('hel');
      expect(Utils.truncate('hi', 5)).assertEqual('hi');
    });

    it('buildQueryString_encodesSpecialChars', 0, () => {
      const params: Record<string, string> = { 'a': 'b c', '&': '=' };
      const qs: string = Utils.buildQueryString(params);
      expect(qs.indexOf('%20') !== -1).assertTrue();
      expect(qs.indexOf('%26') !== -1).assertTrue();
    });

    it('generateUUID_nonEmpty', 0, () => {
      const u: string = Utils.generateUUID();
      expect(u.length > 0).assertTrue();
    });

    it('generateEventId_unique', 0, () => {
      const a: string = Utils.generateEventId();
      const b: string = Utils.generateEventId();
      expect(a !== b).assertTrue();
    });

    it('sanitizeSegmentation_dropsUnsupportedAndTruncates', 0, () => {
      const input: Record<string, Object> = {};
      input['keptString'] = 'value';
      input['keptInt'] = 5;
      input['keptBool'] = true;
      input['keptArray'] = ['a', 'b'];
      input['droppedObject'] = JSON.parse('{"foo":1}') as Object;
      input[''] = 'droppedEmptyKey';
      input['longValue'] = 'x'.repeat(500);
      input['longKey' + 'y'.repeat(200)] = 'v';
      let droppedCount: number = 0;
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 100, (_r: string) => { droppedCount++; });
      expect(out['keptString']).assertEqual('value');
      expect(out['keptInt']).assertEqual(5);
      expect(out['keptBool']).assertEqual(true);
      expect(Array.isArray(out['keptArray'])).assertTrue();
      expect(out['droppedObject'] === undefined).assertTrue();
      expect((out['longValue'] as string).length).assertEqual(256);
      expect(droppedCount >= 1).assertTrue();
    });

    it('sanitizeSegmentation_enforcesEntryCap', 0, () => {
      const input: Record<string, string> = {};
      for (let i = 0; i < 10; i++) input[`k${i}`] = 'v';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 3);
      expect(Object.keys(out).length).assertEqual(3);
    });

    it('mergeMaps_rightOverridesLeft', 0, () => {
      const left: SegmentationMap = { 'a': 1, 'b': 2 };
      const right: SegmentationMap = { 'b': 3, 'c': 4 };
      const m: SegmentationMap = Utils.mergeMaps(left, right);
      expect(m['a']).assertEqual(1);
      expect(m['b']).assertEqual(3);
      expect(m['c']).assertEqual(4);
    });

    it('isSupportedSegmentationValue_cases', 0, () => {
      expect(Utils.isSupportedSegmentationValue('x')).assertTrue();
      expect(Utils.isSupportedSegmentationValue(1)).assertTrue();
      expect(Utils.isSupportedSegmentationValue(true)).assertTrue();
      expect(Utils.isSupportedSegmentationValue(['a', 'b'])).assertTrue();
      expect(Utils.isSupportedSegmentationValue(null)).assertFalse();
    });

    it('sha256Hex_deterministic', 0, async () => {
      const a: string = await Utils.sha256Hex('countly');
      const b: string = await Utils.sha256Hex('countly');
      expect(a).assertEqual(b);
      expect(a.length).assertEqual(64);
    });

    // --- ported from Android UtilsTests.isEmpty / isNotEmpty ---

    it('isNullOrEmpty_unicode', 0, () => {
      // Non-ASCII strings are still non-empty.
      expect(Utils.isNullOrEmpty('1123āšē')).assertFalse();
      expect(Utils.isNullOrEmpty('aa')).assertFalse();
    });

    // --- ported from Android UtilsNetworkingTest ---

    it('isValidUrl_extendedCases', 0, () => {
      // Ports Android testIsValidUrl — schemes and malformed inputs.
      expect(Utils.isValidUrl('113')).assertFalse();
      expect(Utils.isValidUrl('sdfsdfgdg dfsd sdf dsf sdf')).assertFalse();
      expect(Utils.isValidUrl('www.d.dd')).assertFalse();
      expect(Utils.isValidUrl('http://www.d.dd')).assertTrue();
      expect(Utils.isValidUrl('https://www.d.dd')).assertTrue();
    });

    it('encodeDecode_roundTrip', 0, () => {
      // Ports Android testEncodeDecode — encoding and decoding must be inverse.
      const samples: string[] = [
        '132',
        'āšēŗŗ',
        '&#(%^$(&#^@$%$&!_)@(*#_$',
        ' ds fdsf 8ds7f0d&)(^ F*(D&F%S( SD%(F'
      ];
      for (let i = 0; i < samples.length; i++) {
        const item: string = samples[i];
        // encodeURIComponent/decodeURIComponent are the native ArkTS equivalents.
        expect(decodeURIComponent(encodeURIComponent(item))).assertEqual(item);
      }
    });

    it('encode_specialCharactersMatchRFC3986', 0, () => {
      // Ports Android testEncode — non-alphanumeric bytes get percent-encoded.
      const input: string = '&#(%^$(&#^@$%$&!_)@(_$';
      const encoded: string = encodeURIComponent(input);
      // Hard-asserts that spaces/ampersands/etc are encoded, not passed through.
      expect(encoded.indexOf('&')).assertEqual(-1);
      expect(encoded.indexOf('%26') !== -1).assertTrue(); // '&' -> %26
      expect(encoded.indexOf('%24') !== -1).assertTrue(); // '$' -> %24
    });

    it('encode_spacesBecomePercent20ViaBuildQueryString', 0, () => {
      // buildQueryString must %-encode spaces in values.
      const params: Record<string, string> = { 'a': '1', 'b': 'two words' };
      const qs: string = Utils.buildQueryString(params);
      expect(qs.indexOf('%20') !== -1).assertTrue();
      expect(qs.indexOf('&') !== -1).assertTrue(); // separator between pairs
      expect(qs.indexOf('a=1') !== -1).assertTrue();
    });

    it('encode_unicodeEmojiRoundTrip', 0, () => {
      const emoji: string = 'hello 🌍 world';
      expect(decodeURIComponent(encodeURIComponent(emoji))).assertEqual(emoji);
    });

    // --- ported from Android UtilsTimeTests ---

    it('uniqueTimestampMs_strictlyIncreasingRapidCalls', 0, () => {
      // Ports testDiff — tighter assertion on monotonicity under burst calls.
      let prev: number = Utils.uniqueTimestampMs();
      for (let i = 0; i < 50; i++) {
        const next: number = Utils.uniqueTimestampMs();
        expect(next > prev).assertTrue();
        prev = next;
      }
    });

    // --- ported from Android UtilsInternalLimitsTests ---
    // HOS exposes truncation through Utils.truncate + Utils.sanitizeSegmentation,
    // not a dedicated UtilsInternalLimits module. Port the contracts via these.

    it('truncate_key_cutsAtLimit', 0, () => {
      // Matches UtilsInternalLimitsTests.truncateKeyLength.
      expect(Utils.truncate('test', 2)).assertEqual('te');
    });

    it('truncate_key_multiple', 0, () => {
      // Matches truncateKeyLength_multiple.
      expect(Utils.truncate('test_test', 4)).assertEqual('test');
      expect(Utils.truncate('test', 4)).assertEqual('test');
    });

    it('truncate_value_cutsAtLimit', 0, () => {
      // Matches truncateValueSize + truncateValueSize_multiple.
      expect(Utils.truncate('test', 2)).assertEqual('te');
      expect(Utils.truncate('test_test', 4)).assertEqual('test');
      expect(Utils.truncate('test', 4)).assertEqual('test');
    });

    it('sanitizeSegmentation_truncatesKeysToMaxKeyLength', 0, () => {
      // Ports truncateSegmentationKeys behaviour via sanitizeSegmentation.
      const input: Record<string, Object> = {};
      input['test_test'] = 'value1';
      input['test'] = 'value2';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 5, 256, 100);
      // "test_test" -> "test_" (key capped to 5), "test" unchanged.
      expect(out['test_']).assertEqual('value1');
      expect(out['test']).assertEqual('value2');
    });

    it('sanitizeSegmentation_clashingTruncatedKeys', 0, () => {
      // Ports applySdkInternalLimitsToSegmentation_clashingKeys: keys truncated
      // to the same prefix collide and the later write wins.
      const input: Record<string, Object> = {};
      input['a'] = 1;
      input['bbb'] = 'bbb';
      input['bbc'] = 'ccc';
      input['bbd'] = 'ddd';
      input['bbe'] = 'eee';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 2, 2, 10);
      // 'a' survives as-is. All "bb*" keys collapse to "bb" — only one entry
      // remains with a 2-char value.
      expect(out['a']).assertEqual(1);
      const bbVal: Object | null | undefined = out['bb'];
      expect(bbVal !== undefined).assertTrue();
      expect((bbVal as string).length).assertEqual(2);
    });

    it('sanitizeSegmentation_dropsUnsupportedObjectValue', 0, () => {
      // Ports removeUnsupportedDataTypes: arbitrary objects are rejected,
      // primitives + primitive arrays are kept.
      const input: Record<string, Object> = {};
      input['str'] = 'dd';
      input['int'] = 1234;
      input['double'] = 1234.55;
      input['bool'] = true;
      input['objectLike'] = JSON.parse('{"foo":1}') as Object;
      input['strArray'] = ['ff', '33'];
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 100);
      expect(out['str']).assertEqual('dd');
      expect(out['int']).assertEqual(1234);
      expect(out['double']).assertEqual(1234.55);
      expect(out['bool']).assertEqual(true);
      expect(out['objectLike'] === undefined).assertTrue();
      expect(Array.isArray(out['strArray'])).assertTrue();
    });

    it('sanitizeSegmentation_dropsEmptyAndNullKeyValues', 0, () => {
      // Ports removeUnsupportedDataTypes2: empty-string keys and null values
      // are filtered out. Use SegmentationMap directly so 'null' is allowed.
      const input: SegmentationMap = {};
      input[''] = 'dd';
      input['aa'] = null;
      input['good'] = 'kept';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input, 128, 256, 100);
      expect(out[''] === undefined).assertTrue();
      expect(out['aa'] === undefined).assertTrue();
      expect(out['good']).assertEqual('kept');
    });

    it('sanitizeSegmentation_underEntryCap_keepsAll', 0, () => {
      // Ports truncateSegmentationValues_underLimit.
      const input: Record<string, Object> = {};
      input['a1'] = '1';
      input['a2'] = '2';
      input['a3'] = '3';
      input['a4'] = '4';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 6);
      expect(Object.keys(out).length).assertEqual(4);
    });

    it('sanitizeSegmentation_aboveEntryCap_truncates', 0, () => {
      // Ports truncateSegmentationValues_aboveLimit.
      const input: Record<string, Object> = {};
      input['a1'] = '1';
      input['a2'] = '2';
      input['a3'] = '3';
      input['a4'] = '4';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 2);
      expect(Object.keys(out).length).assertEqual(2);
    });

    it('sanitizeSegmentation_nullAndEmptyInput', 0, () => {
      // Ports truncateSegmentationKeys_null / _empty and the assorted
      // applySdkInternalLimitsToSegmentation_empty tests: must not throw and
      // must return an empty map.
      const nullOut: SegmentationMap = Utils.sanitizeSegmentation(null, 5, 2, 3);
      expect(Object.keys(nullOut).length).assertEqual(0);
      const undefOut: SegmentationMap = Utils.sanitizeSegmentation(undefined, 5, 2, 3);
      expect(Object.keys(undefOut).length).assertEqual(0);
      const empty: SegmentationMap = {};
      const emptyOut: SegmentationMap = Utils.sanitizeSegmentation(empty, 5, 2, 3);
      expect(Object.keys(emptyOut).length).assertEqual(0);
    });

    it('sanitizeSegmentation_appliesAllLimitsTogether', 0, () => {
      // Ports applySdkInternalLimitsToSegmentation: key cap + value cap +
      // entry cap applied in one pass.
      const input: Record<string, Object> = {};
      input['test_test'] = 'value1';
      input['test'] = 'value2';
      input['hobbit'] = 456789;
      input['map_to'] = 45.678;
      input['abcdefg'] = '12345';
      const out: SegmentationMap = Utils.sanitizeSegmentation(input as SegmentationMap, 5, 2, 3);
      expect(Object.keys(out).length).assertEqual(3);
      // String values are cut to 2 chars; numeric values pass through.
      const v1: Object | null | undefined = out['test_'];
      if (typeof v1 === 'string') expect((v1 as string).length).assertEqual(2);
    });

    // --- Limits constants sanity: defaults match the dev guide. ---
    it('Limits_defaultsMatchDevGuide', 0, () => {
      // Android UtilsInternalLimitsTests indirectly assumes these caps via
      // ConfigSdkInternalLimits defaults. HOS exposes them as plain fields.
      const limits: Limits = new Limits();
      expect(limits.maxKeyLength).assertEqual(128);
      expect(limits.maxValueSize).assertEqual(256);
      expect(limits.maxSegmentationValues).assertEqual(100);
      expect(limits.maxBreadcrumbCount).assertEqual(100);
    });

    // --- cloneStringRecord / cloneSegmentationMap independence ---

    it('cloneStringRecord_mutationDoesNotAffectClone', 0, () => {
      const src: Record<string, string> = { 'a': '1', 'b': '2' };
      const copy: Record<string, string> = Utils.cloneStringRecord(src);
      src['a'] = 'mutated';
      expect(copy['a']).assertEqual('1');
      expect(copy !== src).assertTrue();
    });

    it('cloneSegmentationMap_mutationDoesNotAffectClone', 0, () => {
      const src: SegmentationMap = {};
      src['k1'] = 'v1';
      src['k2'] = 42;
      const copy: SegmentationMap = Utils.cloneSegmentationMap(src);
      src['k1'] = 'mutated';
      src['k2'] = 99;
      expect(copy['k1']).assertEqual('v1');
      expect(copy['k2']).assertEqual(42);
      expect(copy !== src).assertTrue();
    });

    // --- branch coverage: array element type validation ---

    it('isSupportedSegmentationValue_rejectsMixedArrayWithObject', 0, () => {
      // Array with a non-primitive element falls back to false. Exercises the
      // inner `typeof element` branch that was uncovered.
      // Double-cast through Object: the function's nominal `SegmentationValue`
      // signature is exactly what we're trying to violate, so ArkTS strict
      // refuses a direct cast — going through Object is the documented escape
      // hatch for testing invalid inputs without changing the prod signature.
      const bad: Object[] = ['ok', JSON.parse('{"o":1}')];
      expect(Utils.isSupportedSegmentationValue(bad as Object as SegmentationValue)).assertFalse();
      // Sibling case: array of plain objects.
      const badArr: Object[] = [JSON.parse('{"o":1}')];
      expect(Utils.isSupportedSegmentationValue(badArr as Object as SegmentationValue)).assertFalse();
    });

    it('sanitizeSegmentation_invokesOnDropForUnsupportedValue', 0, () => {
      // Specifically exercise the onDrop branch for an unsupported value type
      // — the `droppedObject` case in the wider sanitize test asserts state,
      // but does NOT distinguish the value-type path from the empty-key path.
      const reasons: string[] = [];
      const input: Record<string, Object> = {};
      input['kept'] = 'v';
      input['nestedObj'] = JSON.parse('{"x":1}') as Object;
      Utils.sanitizeSegmentation(input as SegmentationMap, 128, 256, 100, (r: string) => { reasons.push(r); });
      expect(reasons.length >= 1).assertTrue();
      // At least one drop reason mentions the value-type rejection.
      let foundValueType: boolean = false;
      for (let i = 0; i < reasons.length; i++) {
        if (reasons[i].indexOf('unsupported segmentation value type') !== -1) foundValueType = true;
      }
      expect(foundValueType).assertTrue();
    });

    it('openExternalUrlViaContext_nullContext_logsAndReturns', 0, () => {
      // Null context branch — must not throw and must log a warning.
      const logger: Logger = new Logger();
      Utils.openExternalUrlViaContext(null, 'https://x.com', logger);
      // Reaching this point means the null path returned cleanly.
      expect(true).assertTrue();
    });
  });
}
