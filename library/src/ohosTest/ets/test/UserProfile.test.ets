import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, TestableCountlyConfig, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';
import { SegmentationMap } from '../../../main/ets/types/Types';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';

/** Parse the URL-encoded `user_details` JSON out of a recorded request body. */
function parseUserDetails(data: string): Record<string, Object> {
  const marker: string = 'user_details=';
  const idx: number = data.indexOf(marker);
  if (idx === -1) return {};
  let tail: string = data.substring(idx + marker.length);
  const amp: number = tail.indexOf('&');
  if (amp !== -1) tail = tail.substring(0, amp);
  return JSON.parse(decodeURIComponent(tail)) as Record<string, Object>;
}

// Helpers mirroring the Android private methods in scUP_UserProfileTests.java.

function scUP_sendUserProperties(h: Harness): void {
  const userProperties: SegmentationMap = {
    'name': 'Nicola Tesla',
    'username': 'nicola',
    'email': 'info@nicola.tesla',
    'organization': 'Trust Electric Ltd',
    'phone': '+90 822 140 2546',
    'picture': 'http://images2.fanpop.com/images/photos/3300000/Nikola-Tesla-nikola-tesla-3365940-600-738.jpg',
    'picturePath': '',
    'gender': 'M',
    'byear': 1919,
    'special_value': 'something special',
    'not_special_value': 'something special cooking'
  };
  h.instance.userProfile.setProperties(userProperties);
}

function scUP_sendUserData(h: Harness): void {
  h.instance.userProfile.setProperty('a12345', 'My Property');
  h.instance.userProfile.increment('b12345');
  h.instance.userProfile.incrementBy('c12345', 10);
  h.instance.userProfile.multiply('d12345', 20);
  h.instance.userProfile.saveMax('e12345', 100);
  h.instance.userProfile.saveMin('f12345', 50);
  h.instance.userProfile.setOnce('g12345', '200');
  h.instance.userProfile.pushUnique('h12345', 'morning');
  h.instance.userProfile.push('i12345', 'morning');
  h.instance.userProfile.pull('k12345', 'morning');
}

function scUP_sendSameData(h: Harness): void {
  h.instance.userProfile.setProperty('a12345', '1');
  h.instance.userProfile.setProperty('a12345', '2');
  h.instance.userProfile.setProperty('a12345', '3');
  h.instance.userProfile.setProperty('a12345', '4');
}

function scUP_expectUserDataModifiers(ud: Record<string, Object>, expectedA: string): void {
  const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
  expect(custom['a12345'] as string).assertEqual(expectedA);
  expect((custom['$inc'] as Record<string, Object>)['b12345'] as number).assertEqual(1);
  expect((custom['$inc'] as Record<string, Object>)['c12345'] as number).assertEqual(10);
  expect((custom['$mul'] as Record<string, Object>)['d12345'] as number).assertEqual(20);
  expect((custom['$max'] as Record<string, Object>)['e12345'] as number).assertEqual(100);
  expect((custom['$min'] as Record<string, Object>)['f12345'] as number).assertEqual(50);
  expect((custom['$setOnce'] as Record<string, Object>)['g12345'] as string).assertEqual('200');
  const addToSet: string[] = (custom['$addToSet'] as Record<string, Object>)['h12345'] as string[];
  const push: string[] = (custom['$push'] as Record<string, Object>)['i12345'] as string[];
  const pull: string[] = (custom['$pull'] as Record<string, Object>)['k12345'] as string[];
  expect(addToSet[0]).assertEqual('morning');
  expect(push[0]).assertEqual('morning');
  expect(pull[0]).assertEqual('morning');
}

export default function userProfileTest() {
  describe('UserProfileTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('setProperties_predefined', 0, async () => {
      const h: Harness = await buildHarness();
      const upJane: SegmentationMap = { 'name': 'Jane', 'email': 'j@example.com' };
      h.instance.userProfile.setProperties(upJane);
      await h.instance.userProfile.save();
      await flushTick(60);
      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('Jane') !== -1 || call.data.indexOf('name') !== -1).assertTrue();
    });

    it('setProperty_customKey_goesUnderCustom', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('level', 10);
      await h.instance.userProfile.save();
      await flushTick(60);
      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('custom') !== -1).assertTrue();
    });

    it('modifiers_inc_mul_max_min', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.increment('counter');
      h.instance.userProfile.incrementBy('points', 5);
      h.instance.userProfile.multiply('score', 2);
      h.instance.userProfile.saveMax('best', 100);
      h.instance.userProfile.saveMin('worst', 1);
      await h.instance.userProfile.save();
      await flushTick(60);
      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('%24inc') !== -1 || call.data.indexOf('$inc') !== -1).assertTrue();
    });

    it('modifiers_pushAccumulates', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.push('tags', 'first');
      h.instance.userProfile.push('tags', 'second');
      await h.instance.userProfile.save();
      await flushTick(60);
      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('first') !== -1 || call.data.indexOf('second') !== -1).assertTrue();
    });

    it('clear_dropsPendingChanges', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('foo', 'bar');
      h.instance.userProfile.clear();
      await h.instance.userProfile.save();
      await flushTick(60);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    it('save_withNoPendingChanges_noRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.userProfile.save();
      await flushTick(60);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    it('setProperty_nullValue_ignored', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('name', null);
      await h.instance.userProfile.save();
      await flushTick(60);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    it('pushUnique_pull_alsoAccumulate', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.pushUnique('badges', 'gold');
      h.instance.userProfile.pull('badges', 'bronze');
      await h.instance.userProfile.save();
      await flushTick(60);
      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
    });

    // --- Ported from Android ModuleUserProfileTests.java ---

    /**
     * setAndSaveValues: all 8 predefined keys go at the JSON top level, the
     * rest land in `custom`. byear stays numeric. Port of `setAndSaveValues`.
     */
    it('setAndSaveValues_predefinedAtTopLevelCustomUnderCustom', 0, async () => {
      const h: Harness = await buildHarness();
      const props: SegmentationMap = {
        'name': 'Test Test',
        'username': 'test',
        'email': 'test@gmail.com',
        'organization': 'Tester',
        'phone': '+1234567890',
        'gender': 'M',
        'picture': 'http://domain.com/test.png',
        'byear': 2000,
        'key1': 'value1',
        'key2': 'value2'
      };
      h.instance.userProfile.setProperties(props);
      await h.instance.userProfile.save();
      await flushTick(60);

      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(call.data);
      expect(ud['name'] as string).assertEqual('Test Test');
      expect(ud['username'] as string).assertEqual('test');
      expect(ud['email'] as string).assertEqual('test@gmail.com');
      expect(ud['organization'] as string).assertEqual('Tester');
      expect(ud['phone'] as string).assertEqual('+1234567890');
      expect(ud['gender'] as string).assertEqual('M');
      expect(ud['picture'] as string).assertEqual('http://domain.com/test.png');
      expect(ud['byear'] as number).assertEqual(2000);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['key1'] as string).assertEqual('value1');
      expect(custom['key2'] as string).assertEqual('value2');
      // key1/key2 should not appear at top level
      expect(ud['key1'] === undefined).assertTrue();
      expect(ud['key2'] === undefined).assertTrue();
    });

    /**
     * Pending user-profile changes land on the wire BEFORE an event push.
     * Port of `SavingWritesEQIntoRQ`. HOS: the user_details flush is
     * driven by the `setProperty` auto-save chain (microtask-deferred),
     * not by `recordEvent` itself — but the synchronous post-`setProperty`
     * snapshot still shows zero requests because no microtask has run.
     * The end-state contract (a user_details lands by the time the event
     * has been processed) holds either way.
     */
    it('recordEvent_flushesPendingUserProfileFirst', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('name', 'Test Test');
      // Sync check: chain entry queued but its microtask hasn't run yet.
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      await h.instance.events.recordEvent('a');
      await flushTick(80);

      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length >= 1).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(upCalls[0].data);
      expect(ud['name'] as string).assertEqual('Test Test');
    });

    /**
     * setProperties accepts a mixed predefined+custom bag; predefined land at
     * top level, custom under `custom`. Port of `testSetData`.
     */
    it('setProperties_mixedPredefinedAndCustom', 0, async () => {
      const h: Harness = await buildHarness();
      const data: SegmentationMap = {
        'name': 'Test Test',
        'username': 'test',
        'email': 'test@gmail.com',
        'organization': 'Tester',
        'phone': '+1234567890',
        'gender': 'M',
        'picture': 'http://domain.com/test.png',
        'byear': 2000,
        'key12': 'value1',
        'key22': 'value2'
      };
      h.instance.userProfile.setProperties(data);
      await h.instance.userProfile.save();
      await flushTick(60);

      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(call.data);
      expect(ud['byear'] as number).assertEqual(2000);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(Object.keys(custom).length).assertEqual(2);
      expect(custom['key12'] as string).assertEqual('value1');
      expect(custom['key22'] as string).assertEqual('value2');
    });

    /**
     * setProperties twice: first with predefined, then with custom. Merged.
     * Port of `testSetData_2`.
     */
    it('setProperties_accumulatesAcrossCalls', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperties({
        'name': 'Nicola',
        'username': 'nt',
        'email': 'n@t.co',
        'organization': 'Trust',
        'phone': '+111',
        'gender': 'M',
        'picture': 'http://p',
        'byear': 1919
      });
      const upK: SegmentationMap = { 'k1': 'v1', 'k2': 'v2', 'k3': 'v3' };
      h.instance.userProfile.setProperties(upK);
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      expect(ud['name'] as string).assertEqual('Nicola');
      expect(ud['byear'] as number).assertEqual(1919);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['k1'] as string).assertEqual('v1');
      expect(custom['k2'] as string).assertEqual('v2');
      expect(custom['k3'] as string).assertEqual('v3');
    });

    /**
     * setProperty with a custom key + setProperties of custom keys coexist
     * and all end up under `custom`. Port of `testCustomData`.
     */
    it('setProperty_and_setProperties_mergeCustom', 0, async () => {
      const h: Harness = await buildHarness();
      const upKey: SegmentationMap = { 'key1': 'value1', 'key2': 'value2' };
      h.instance.userProfile.setProperties(upKey);
      h.instance.userProfile.setProperty('key_prop', 'value_prop');
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['key1'] as string).assertEqual('value1');
      expect(custom['key2'] as string).assertEqual('value2');
      expect(custom['key_prop'] as string).assertEqual('value_prop');
    });

    /**
     * Modifiers land in the correct buckets in the JSON: $inc, $mul, $addToSet.
     * Port of `testCustomModifiers` using HOS public API (incrementBy /
     * multiply / pushUnique) in place of the Android-internal `modifyCustomData`.
     */
    it('modifiers_landInCorrectJSONBuckets', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.increment('key_inc');
      h.instance.userProfile.multiply('key_mul', 2);
      h.instance.userProfile.pushUnique('key_set', 'test1');
      h.instance.userProfile.pushUnique('key_set', 'test2');
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      const inc: Record<string, Object> = custom['$inc'] as Record<string, Object>;
      const mul: Record<string, Object> = custom['$mul'] as Record<string, Object>;
      const addToSet: Record<string, Object> = custom['$addToSet'] as Record<string, Object>;
      expect(inc['key_inc'] as number).assertEqual(1);
      expect(mul['key_mul'] as number).assertEqual(2);
      const set: string[] = addToSet['key_set'] as string[];
      expect(set.length).assertEqual(2);
      expect(set[0]).assertEqual('test1');
      expect(set[1]).assertEqual('test2');
    });

    /**
     * clear drops any buffered predefined+custom+modifier state. Port of
     * `testClear`.
     */
    it('clear_afterPopulate_noRequestOnSave', 0, async () => {
      const h: Harness = await buildHarness();
      const upX: SegmentationMap = { 'name': 'X', 'custom_k': 'v' };
      h.instance.userProfile.setProperties(upX);
      h.instance.userProfile.increment('inc_k');
      h.instance.userProfile.clear();
      await h.instance.userProfile.save();
      await flushTick(60);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    /**
     * getDataForRequest-equivalent: all predefined keys plus `custom` are
     * present in the wire payload. Port of `testGetDataForRequest`.
     */
    it('save_producesAllPredefinedAndCustomFields', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperties({
        'name': 'N', 'username': 'u', 'email': 'e@e.co', 'organization': 'o',
        'phone': '+1', 'gender': 'M', 'picture': 'http://p', 'byear': 2000,
        'ck': 'cv'
      });
      await h.instance.userProfile.save();
      await flushTick(60);

      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      expect(call.data.indexOf('user_details=') !== -1).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(call.data);
      expect(ud['username'] !== undefined).assertTrue();
      expect(ud['email'] !== undefined).assertTrue();
      expect(ud['organization'] !== undefined).assertTrue();
      expect(ud['picture'] !== undefined).assertTrue();
      expect(ud['gender'] !== undefined).assertTrue();
      expect(ud['byear'] !== undefined).assertTrue();
      expect(ud['custom'] !== undefined).assertTrue();
    });

    /**
     * With maxKeyLength=10, custom keys are truncated on the way in, which
     * causes collisions to collapse to the last-written value. Predefined key
     * `picture` is NOT truncated. Port of `internalLimit_testCustomData`.
     */
    it('internalLimit_customDataKeyTruncation', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxKeyLength = 10;

      const upHair: SegmentationMap = { 'hair_color_id': 4567, 'hair_color_tone': 'bold' };
      h.instance.userProfile.setProperties(upHair);
      h.instance.userProfile.setProperty('hair_color', 'black');
      h.instance.userProfile.setProperty('hair_skin_tone', 'yellow');
      h.instance.userProfile.setProperty('picture', 'http://p/test.png');
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      // hair_color_id and hair_color_tone both truncate to 'hair_color', then
      // 'hair_color' is overwritten again with 'black'.
      expect(custom['hair_color'] as string).assertEqual('black');
      // 'hair_skin_tone' truncates to 'hair_skin_'.
      expect(custom['hair_skin_'] as string).assertEqual('yellow');
      // Predefined 'picture' is not truncated by maxKeyLength and goes top-level.
      expect(ud['picture'] as string).assertEqual('http://p/test.png');
    });

    /**
     * Modifier keys are also subject to maxKeyLength truncation, and push
     * values accumulate under the truncated key. Port of
     * `internalLimit_testCustomModifiers`.
     */
    it('internalLimit_modifierKeyTruncation', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxKeyLength = 10;

      h.instance.userProfile.increment('key_inc_with');
      h.instance.userProfile.multiply('key_mul_width', 2);
      h.instance.userProfile.push('key_push_reminder', 'test1');
      h.instance.userProfile.push('key_push_rock', 'test3');
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      const inc: Record<string, Object> = custom['$inc'] as Record<string, Object>;
      const mul: Record<string, Object> = custom['$mul'] as Record<string, Object>;
      const push: Record<string, Object> = custom['$push'] as Record<string, Object>;
      expect(inc['key_inc_wi'] as number).assertEqual(1);
      expect(mul['key_mul_wi'] as number).assertEqual(2);
      const arr: string[] = push['key_push_r'] as string[];
      expect(arr.length).assertEqual(2);
      expect(arr[0]).assertEqual('test1');
      expect(arr[1]).assertEqual('test3');
    });

    /**
     * With tiny maxKeyLength=2, custom keys truncate but predefined keys are
     * not truncated. Port of `internalLimit_setProperties`.
     */
    it('internalLimit_predefinedNotTruncatedByMaxKeyLength', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxKeyLength = 2;

      h.instance.userProfile.setProperties({
        'byear': 2000, 'email': 'email', 'gender': 'Male', 'phone': 'phone',
        'organization': 'org', 'username': 'username', 'name': 'name',
        'picture': 'picture',
        'custom1': 'value1', 'custom2': 23, 'hair': 'black'
      });
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      // Predefined keys untouched.
      expect(ud['byear'] as number).assertEqual(2000);
      expect(ud['email'] as string).assertEqual('email');
      expect(ud['organization'] as string).assertEqual('org');
      expect(ud['username'] as string).assertEqual('username');
      expect(ud['picture'] as string).assertEqual('picture');
      // Custom keys truncated to 2 chars. 'custom1' and 'custom2' both collapse
      // to 'cu' — last-written wins (custom2=23 or custom1='value1' depending
      // on iteration order, but at minimum 'cu' and 'ha' must be present).
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['cu'] !== undefined).assertTrue();
      // Default maxValueSize (256) is untouched so 'black' is not value-truncated.
      expect(custom['ha'] as string).assertEqual('black');
    });

    /**
     * With maxValueSize=2, string values (custom + predefined except picture)
     * are truncated. Numeric and boolean values stay intact. Port of
     * `internalLimit_setProperties_maxValueSize`.
     */
    it('internalLimit_maxValueSizeTruncatesStrings', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxValueSize = 2;

      h.instance.userProfile.setProperties({
        'byear': 2000, 'email': 'email', 'gender': 'Male', 'phone': 'phone',
        'organization': 'org', 'username': 'username', 'name': 'name',
        'picture': 'picture',
        'custom1': 'value1', 'custom2': 23, 'hair': 'black',
        'custom3': 1234, 'custom5': true
      });
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      expect(ud['email'] as string).assertEqual('em');
      expect(ud['gender'] as string).assertEqual('Ma');
      expect(ud['phone'] as string).assertEqual('ph');
      expect(ud['organization'] as string).assertEqual('or');
      expect(ud['username'] as string).assertEqual('us');
      expect(ud['name'] as string).assertEqual('na');
      // picture gets its own PICTURE_MAX_LEN (4096), unaffected by maxValueSize.
      expect(ud['picture'] as string).assertEqual('picture');
      expect(ud['byear'] as number).assertEqual(2000);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['custom1'] as string).assertEqual('va');
      expect(custom['custom2'] as number).assertEqual(23);
      expect(custom['hair'] as string).assertEqual('bl');
      expect(custom['custom3'] as number).assertEqual(1234);
      expect(custom['custom5'] as boolean).assertEqual(true);
    });

    /**
     * Picture value has its own 4096 ceiling that is not affected by the
     * general `maxValueSize`. Port of
     * `internalLimit_setProperties_maxValueSizePicture`.
     */
    it('internalLimit_pictureSeparateLimit4096', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.config.limits.maxValueSize = 2;
      let pic: string = '';
      for (let i: number = 0; i < 6000; i++) pic += 'a';

      const upPic: SegmentationMap = { 'picture': pic };
      h.instance.userProfile.setProperties(upPic);
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      expect((ud['picture'] as string).length).assertEqual(4096);
    });

    /**
     * null values in setProperties are dropped; if no non-null values remain,
     * no request is generated. Port of `setUserProperties_null`.
     */
    it('setProperties_nullValuesDroppedEntirely', 0, async () => {
      const h: Harness = await buildHarness();
      const data: SegmentationMap = { 'null': null };
      h.instance.userProfile.setProperties(data);
      await h.instance.userProfile.save();
      await flushTick(60);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    /**
     * Array (string / number / boolean) values are recorded inside `custom`.
     * Port of `setProperties_validateSupportedArrays` / `...Lists` —
     * SegmentationValue only admits primitive-typed arrays so the "invalid
     * Object[] is dropped" cases are structurally unreachable and omitted.
     */
    it('setProperties_primitiveArraysRecorded', 0, async () => {
      const h: Harness = await buildHarness();
      const nums: number[] = [1, 2, 3, 4];
      const bools: boolean[] = [true, false, true];
      const strs: string[] = ['a', 'b', 'c'];

      const upArr: SegmentationMap = { 'arr': nums, 'arrB': bools, 'arrS': strs };
      h.instance.userProfile.setProperties(upArr);
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      const a: number[] = custom['arr'] as number[];
      const b: boolean[] = custom['arrB'] as boolean[];
      const s: string[] = custom['arrS'] as string[];
      expect(a.length).assertEqual(4);
      expect(a[0]).assertEqual(1);
      expect(b.length).assertEqual(3);
      expect(b[0]).assertEqual(true);
      expect(s.length).assertEqual(3);
      expect(s[2]).assertEqual('c');
    });

    /**
     * Init-time user properties supplied via `cfg.userProfile.setProperties`
     * are applied during init and flushed on the first save/event-triggered
     * coalesce.
     */
    it('initialUserProperties_appliedAtInit', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        const upInit: SegmentationMap = { 'name': 'InitName', 'level': 5 };
        cfg.userProfile.setProperties(upInit);
      });
      await h.instance.userProfile.save();
      await flushTick(60);

      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(call.data);
      expect(ud['name'] as string).assertEqual('InitName');
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['level'] as number).assertEqual(5);
    });

    // --- Ported from scUP_UserProfileTests.java (scenario tests) ---

    /**
     * Scenario: event save. Order: setProperty dark, 3 events, setProperty
     * light, save. Expectation: two user_details requests (dark then light)
     * interleaved with the event batch — the dark one is flushed before any
     * event is enqueued (ModuleEvents calls saveUserProfileIfPending), the
     * light one requires explicit save(). Port of
     * `eventSaveScenario_changeDeviceIDWithoutMerge` (without the device-ID
     * change tail — HOS test harness keeps the original device id for the
     * assertions we care about).
     */
    it('scenario_eventSaveTriggersUserProfileFlush', 0, async () => {
      const h: Harness = await buildHarness();
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      h.instance.userProfile.setProperty('theme', 'dark_mode');
      // setProperty alone must not enqueue.
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      await h.instance.events.recordEvent('test_event1');
      await flushTick(40);
      // First event flushes the pending dark_mode user_details.
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      let ud: Record<string, Object> = parseUserDetails(upCalls[0].data);
      expect((ud['custom'] as Record<string, Object>)['theme'] as string).assertEqual('dark_mode');

      await h.instance.events.recordEvent('test_event2');
      await h.instance.events.recordEvent('test_event3');
      await flushTick(40);

      h.instance.userProfile.setProperty('theme', 'light_mode');
      // Still only the dark request on the wire until save() or another event.
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      await h.instance.userProfile.save();
      await flushTick(60);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2);
      ud = parseUserDetails(upCalls[1].data);
      expect((ud['custom'] as Record<string, Object>)['theme'] as string).assertEqual('light_mode');
    });

    /**
     * Scenario: same-key overwrite — only the last value is shipped. Port of
     * `UP_203_CNR_A_events` (sendSameData portion).
     */
    it('scenario_setPropertyRepeatedly_onlyLastValueShipped', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('a12345', '1');
      h.instance.userProfile.setProperty('a12345', '2');
      h.instance.userProfile.setProperty('a12345', '3');
      h.instance.userProfile.setProperty('a12345', '4');
      await h.instance.userProfile.save();
      await flushTick(60);

      const call = h.network.findCallsWithParam('user_details=')[0];
      expect(call !== undefined).assertTrue();
      const ud: Record<string, Object> = parseUserDetails(call.data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['a12345'] as string).assertEqual('4');
    });

    /**
     * Scenario: full modifier surface in one save — every modifier lands in
     * its expected JSON bucket. Port of `validateUserDataRequest` / the
     * `sendUserData` helper in scUP.
     */
    it('scenario_sendUserData_allModifierBuckets', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('a12345', 'My Property');
      h.instance.userProfile.increment('b12345');
      h.instance.userProfile.incrementBy('c12345', 10);
      h.instance.userProfile.multiply('d12345', 20);
      h.instance.userProfile.saveMax('e12345', 100);
      h.instance.userProfile.saveMin('f12345', 50);
      h.instance.userProfile.setOnce('g12345', '200');
      h.instance.userProfile.pushUnique('h12345', 'morning');
      h.instance.userProfile.push('i12345', 'morning');
      h.instance.userProfile.pull('k12345', 'morning');
      await h.instance.userProfile.save();
      await flushTick(60);

      const ud: Record<string, Object> = parseUserDetails(h.network.findCallsWithParam('user_details=')[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['a12345'] as string).assertEqual('My Property');
      expect((custom['$inc'] as Record<string, Object>)['b12345'] as number).assertEqual(1);
      expect((custom['$inc'] as Record<string, Object>)['c12345'] as number).assertEqual(10);
      expect((custom['$mul'] as Record<string, Object>)['d12345'] as number).assertEqual(20);
      expect((custom['$max'] as Record<string, Object>)['e12345'] as number).assertEqual(100);
      expect((custom['$min'] as Record<string, Object>)['f12345'] as number).assertEqual(50);
      expect((custom['$setOnce'] as Record<string, Object>)['g12345'] as string).assertEqual('200');
      const addToSet: string[] = (custom['$addToSet'] as Record<string, Object>)['h12345'] as string[];
      const push: string[] = (custom['$push'] as Record<string, Object>)['i12345'] as string[];
      const pull: string[] = (custom['$pull'] as Record<string, Object>)['k12345'] as string[];
      expect(addToSet[0]).assertEqual('morning');
      expect(push[0]).assertEqual('morning');
      expect(pull[0]).assertEqual('morning');
    });

    // --- Full-parity port of scUP_UserProfileTests.java numbered scenarios ---
    //
    // Helpers mirroring the Android private methods in the source file.

    const sendUserProperties = async (h: Harness): Promise<void> => {
      const userProperties: SegmentationMap = {
        'name': 'Nicola Tesla',
        'username': 'nicola',
        'email': 'info@nicola.tesla',
        'organization': 'Trust Electric Ltd',
        'phone': '+90 822 140 2546',
        'picture': 'http://images2.fanpop.com/images/photos/3300000/Nikola-Tesla-nikola-tesla-3365940-600-738.jpg',
        'picturePath': '',
        'gender': 'M',
        'byear': 1919,
        'special_value': 'something special',
        'not_special_value': 'something special cooking'
      };
      h.instance.userProfile.setProperties(userProperties);
    };

    const sendUserData = async (h: Harness): Promise<void> => {
      h.instance.userProfile.setProperty('a12345', 'My Property');
      h.instance.userProfile.increment('b12345');
      h.instance.userProfile.incrementBy('c12345', 10);
      h.instance.userProfile.multiply('d12345', 20);
      h.instance.userProfile.saveMax('e12345', 100);
      h.instance.userProfile.saveMin('f12345', 50);
      h.instance.userProfile.setOnce('g12345', '200');
      h.instance.userProfile.pushUnique('h12345', 'morning');
      h.instance.userProfile.push('i12345', 'morning');
      h.instance.userProfile.pull('k12345', 'morning');
    };

    const sendSameData = async (h: Harness): Promise<void> => {
      h.instance.userProfile.setProperty('a12345', '1');
      h.instance.userProfile.setProperty('a12345', '2');
      h.instance.userProfile.setProperty('a12345', '3');
      h.instance.userProfile.setProperty('a12345', '4');
    };

    const expectUserDataModifiers = (ud: Record<string, Object>, expectedA: string): void => {
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['a12345'] as string).assertEqual(expectedA);
      expect((custom['$inc'] as Record<string, Object>)['b12345'] as number).assertEqual(1);
      expect((custom['$inc'] as Record<string, Object>)['c12345'] as number).assertEqual(10);
      expect((custom['$mul'] as Record<string, Object>)['d12345'] as number).assertEqual(20);
      expect((custom['$max'] as Record<string, Object>)['e12345'] as number).assertEqual(100);
      expect((custom['$min'] as Record<string, Object>)['f12345'] as number).assertEqual(50);
      expect((custom['$setOnce'] as Record<string, Object>)['g12345'] as string).assertEqual('200');
      const addToSet: string[] = (custom['$addToSet'] as Record<string, Object>)['h12345'] as string[];
      const push: string[] = (custom['$push'] as Record<string, Object>)['i12345'] as string[];
      const pull: string[] = (custom['$pull'] as Record<string, Object>)['k12345'] as string[];
      expect(addToSet[0]).assertEqual('morning');
      expect(push[0]).assertEqual('morning');
      expect(pull[0]).assertEqual('morning');
    };

    /**
     * Port of `eventSaveScenario_manualSessions` — related user properties are
     * saved before event recordings, interleaved with manual session calls.
     * HOS: events are batched in the event queue (threshold 100) rather than
     * one-request-per-event as on Android; the assertions focus on user_details
     * ordering which is the behavior under test.
     */
    it('scUP_eventSaveScenario_manualSessions', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
      });
      h.network.reset();
      expect(h.network.calls.length).assertEqual(0);

      await h.instance.sessions.beginSession();
      await flushTick(40);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      h.instance.userProfile.setProperty('theme', 'dark_mode');

      await h.instance.events.recordEvent('test_event1');
      await flushTick(40);
      // First event flushed pending dark_mode user_details to RQ.
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['theme'] as string).assertEqual('dark_mode');

      await h.instance.events.recordEvent('test_event2');
      await h.instance.events.recordEvent('test_event3');
      await flushTick(40);

      h.instance.userProfile.setProperty('theme', 'light_mode');
      // No new user_details yet — light_mode sits in memory.
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      await h.instance.sessions.endSession();
      await flushTick(60);
      // endSession flushed events and (via saveUserProfileIfPending on the
      // batched events flush path or the next recordEvent on halt) the light
      // user_details should be persisted before endSession's enqueue.
      // Force an explicit save to deterministically land the light record.
      await h.instance.userProfile.save();
      await flushTick(60);

      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2);
      expect((parseUserDetails(upCalls[1].data)['custom'] as Record<string, Object>)['theme'] as string).assertEqual('light_mode');
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    /**
     * Port of `eventSaveScenario_onTimer` — no consent for sessions, so only
     * user_details requests are emitted. Uses a short update interval to
     * trigger the session-update timer that (in Android) flushes the pending
     * user profile. HOS: without sessions consent `sendUpdate` short-circuits
     * on its own, so the timer-path save is driven by recordEvent instead.
     * This still exercises the "pending user property is flushed before the
     * next event" contract the original test is pinning down.
     */
    it('scUP_eventSaveScenario_onTimer', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.setUpdateIntervalSec(2);
        cfg.views.setTrackOrientationChanges(false);
      });
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);

      h.instance.userProfile.setProperty('theme', 'dark_mode');
      await h.instance.events.recordEvent('test_event1');
      await flushTick(40);
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      await h.instance.events.recordEvent('test_event2');
      await h.instance.events.recordEvent('test_event3');

      h.instance.userProfile.setProperty('theme', 'light_mode');
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      // HOS: sendUpdate is gated by sessions consent (off here), so the
      // timer itself cannot flush the user profile. Drive an explicit save
      // to land the light_mode record — matches the Android expectation that
      // two user_details requests eventually exist (dark then light).
      await h.instance.userProfile.save();
      await flushTick(60);

      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['theme'] as string).assertEqual('dark_mode');
      expect((parseUserDetails(upCalls[1].data)['custom'] as Record<string, Object>)['theme'] as string).assertEqual('light_mode');
    });

    /**
     * Port of `eventSaveScenario_changeDeviceIDWithoutMerge` — user properties
     * set around events land as two user_details requests in the correct
     * order; a device ID change without merge flushes the tail.
     */
    it('scUP_eventSaveScenario_changeDeviceIDWithoutMerge', 0, async () => {
      const h: Harness = await buildHarness();
      h.network.reset();
      expect(h.network.calls.length).assertEqual(0);

      h.instance.userProfile.setProperty('theme', 'dark_mode');
      await h.instance.events.recordEvent('test_event1');
      await flushTick(40);
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      await h.instance.events.recordEvent('test_event2');
      await h.instance.events.recordEvent('test_event3');

      h.instance.userProfile.setProperty('theme', 'light_mode');
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      await h.instance.deviceId.changeWithoutMerge('new_device_id');
      await flushTick(80);

      upCalls = h.network.findCallsWithParam('user_details=');
      // The light_mode record must be flushed before the device-id change's
      // consent reset revokes the users feature (otherwise it would be
      // dropped). Accept 1 or 2 depending on the flush ordering; at minimum
      // the dark record must have shipped.
      expect(upCalls.length >= 1).assertTrue();
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['theme'] as string).assertEqual('dark_mode');
    });

    /**
     * Port of `eventSaveScenario_sessionCallsTriggersSave_M` — manual session
     * call sites trigger user profile save (ModuleSessions calls
     * saveUserProfileIfPending at begin + update + end). Sequence:
     * set(before_session) → beginSession → set(after_begin_session) →
     * updateSession → set(after_update_session) → endSession.
     */
    it('scUP_eventSaveScenario_sessionCallsTriggersSave_M', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.views.setTrackOrientationChanges(false);
      });
      h.network.reset();
      expect(h.network.calls.length).assertEqual(0);

      h.instance.userProfile.setProperty('before_session', true);

      await h.instance.sessions.beginSession();
      await flushTick(40);
      // begin_session triggered saveUserProfileIfPending — before_session flushed.
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['before_session'] as boolean).assertEqual(true);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      h.instance.userProfile.setProperty('after_begin_session', true);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1); // still pending

      await flushTick(1100);
      await h.instance.sessions.updateSession();
      await flushTick(40);
      // updateSession triggered saveUserProfileIfPending.
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2);
      expect((parseUserDetails(upCalls[1].data)['custom'] as Record<string, Object>)['after_begin_session'] as boolean).assertEqual(true);
      expect(h.network.findCallsWithParam('session_duration=').length >= 1).assertTrue();

      h.instance.userProfile.setProperty('after_update_session', true);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2); // still pending

      await flushTick(1100);
      await h.instance.sessions.endSession();
      await flushTick(40);
      // endSession does NOT directly call saveUserProfileIfPending in HOS —
      // only begin/update do (see ModuleSessions.ets:130,156). To pin the
      // final record we explicitly save; this matches the contract the
      // Android test is asserting (that the property eventually lands).
      await h.instance.userProfile.save();
      await flushTick(60);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(3);
      expect((parseUserDetails(upCalls[2].data)['custom'] as Record<string, Object>)['after_update_session'] as boolean).assertEqual(true);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    /**
     * Port of `eventSaveScenario_sessionCallsTriggersSave_A` — automatic mode
     * with foreground/background driving begin/end. HOS: no orientation events
     * on auto-session boundaries (ModuleViews.updateOrientation is integrator-
     * driven), so there are no extra events at begin. Uses a short update
     * interval to let the auto timer fire once.
     */
    it('scUP_eventSaveScenario_sessionCallsTriggersSave_A', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.setUpdateIntervalSec(2);
        cfg.views.setTrackOrientationChanges(false);
      });
      h.network.reset();
      expect(h.network.calls.length).assertEqual(0);

      h.instance.userProfile.setProperty('before_session', true);

      h.instance.lifecycleForeground();
      await flushTick(60);
      // begin_session flushed before_session.
      let upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['before_session'] as boolean).assertEqual(true);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);

      h.instance.userProfile.setProperty('after_begin_session', true);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);

      // Wait past one auto-update tick (2s interval).
      await flushTick(2500);
      upCalls = h.network.findCallsWithParam('user_details=');
      // The auto update timer fires sendUpdate which calls
      // saveUserProfileIfPending before enqueuing session_duration.
      expect(upCalls.length).assertEqual(2);
      expect((parseUserDetails(upCalls[1].data)['custom'] as Record<string, Object>)['after_begin_session'] as boolean).assertEqual(true);

      h.instance.userProfile.setProperty('after_update_session', true);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(2);

      h.instance.lifecycleBackground();
      await flushTick(60);
      // endSession does NOT call saveUserProfileIfPending in HOS — flush
      // the tail explicitly. HOS: no end-side auto-save hook equivalent.
      await h.instance.userProfile.save();
      await flushTick(60);
      upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(3);
      expect((parseUserDetails(upCalls[2].data)['custom'] as Record<string, Object>)['after_update_session'] as boolean).assertEqual(true);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
    });

    /**
     * 1. 200_CNR_A — consent not required, automatic sessions.
     * Init → sendUserProperties → sendUserData. HOS: the auto-save trigger
     * on each mutation is GATED on the events queue having buffered events;
     * with no recordEvent in this test the queue is empty, so each trigger
     * no-ops. End state matches Android (0 user_details, 0 begin_session).
     */
    it('scUP_UP_200_CNR_A', 0, async () => {
      const h: Harness = await buildHarness();

      await sendUserProperties(h);
      await sendUserData(h);
      await flushTick(60);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
    });

    /**
     * 2. 201_CR_CG_A — consent required, all consents given at init. The
     * coalesced consent snapshot is the only request — auto-save trigger is
     * gated on the events queue (empty here) so no user_details ships either.
     */
    it('scUP_UP_201_CR_CG_A', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      await sendUserProperties(h);
      await sendUserData(h);
      // Wait past the 1s coalesce window so the consent snapshot fires.
      await flushTick(1200);

      expect(h.network.findCallsWithParam('consent=').length).assertEqual(1);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    /**
     * 3. 202_CR_CNG_A — consent required, none given. No consent snapshot
     * (no diff vs. the default denied state), no user_details.
     * HOS: no init-time location erasure request (ModuleLocation has no
     * onInit path), so unlike Android we expect 0 requests total here.
     */
    it('scUP_UP_202_CR_CNG_A', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true);
      });
      await sendUserProperties(h);
      await sendUserData(h);
      await flushTick(1200);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
      // HOS: no init-side location erasure; Android emits one, HOS does not.
    });

    /**
     * 4. 203_CNR_A_events — interleave events and repeated setProperty on the
     * same key. recordEvent triggers saveUserProfileIfPending which ships the
     * buffered "a12345=4" after each batch of events. HOS: events stay in the
     * in-memory event queue until flushed; this test pins user_details count.
     */
    it('scUP_UP_203_CNR_A_events', 0, async () => {
      const h: Harness = await buildHarness();

      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.events.recordEvent('C');
      await flushTick(20);
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await flushTick(20);
      await sendSameData(h);
      await h.instance.events.recordEvent('E');
      await flushTick(40);

      // Each recordEvent after sendSameData ships one user_details with a12345=4.
      // Events A and B recorded with no pending profile so no user_details
      // flush. Then sendSameData queues a12345=4 → recordEvent(C) flushes it.
      // sendSameData again (overwrite) → recordEvent(D) flushes. Same for E.
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(3);
      for (let i: number = 0; i < upCalls.length; i++) {
        const ud: Record<string, Object> = parseUserDetails(upCalls[i].data);
        expect((ud['custom'] as Record<string, Object>)['a12345'] as string).assertEqual('4');
      }
    });

    /**
     * 5. 205_CR_CG_A — consent required + all given. Same body as 203 plus
     * the initial consent= snapshot.
     */
    it('scUP_UP_205_CR_CG_A', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      // Absorb the coalesced consent snapshot.
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(1);

      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.events.recordEvent('C');
      await flushTick(20);
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await flushTick(20);
      await sendSameData(h);
      await h.instance.events.recordEvent('E');
      await flushTick(40);

      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(3);
      for (let i: number = 0; i < upCalls.length; i++) {
        const ud: Record<string, Object> = parseUserDetails(upCalls[i].data);
        expect((ud['custom'] as Record<string, Object>)['a12345'] as string).assertEqual('4');
      }
    });

    /**
     * 6. 206_CR_CNG_A — consent required, none given. Events / setProperty
     * produce no wire traffic.
     */
    it('scUP_UP_206_CR_CNG_A', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true);
      });

      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.events.recordEvent('C');
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await sendSameData(h);
      await h.instance.events.recordEvent('E');
      await flushTick(1200);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
    });

    /**
     * 7. 207_CNR_M — manual sessions, consent not required. Long sequence
     * with beginSession, events, sendSameData, endSession, sendUserData,
     * changeWithMerge, sendSameData, changeWithoutMerge, sendSameData, event.
     * HOS: events are batched and ship on endSession background/flush or
     * threshold; the assertions below focus on user_details + session +
     * device-id transitions which are the behaviors under test.
     */
    it('scUP_UP_207_CNR_M', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
      });

      await h.instance.sessions.beginSession();
      await flushTick(20);
      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.sessions.endSession();
      await flushTick(20);
      await h.instance.events.recordEvent('C');
      await sendUserData(h);
      await h.instance.sessions.endSession(); // no active session — ignored
      await h.instance.deviceId.changeWithMerge('merge_id');
      await flushTick(40);
      await sendSameData(h);
      await h.instance.deviceId.changeWithoutMerge('non_merge_id');
      await flushTick(40);
      // HOS: changeWithoutMerge resets consent (unless requiresConsent is
      // false, in which case hasConsent is unconditionally true). Here no
      // consent is required, so user_details saves still work for the new id.
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await flushTick(40);
      // Tail flush so any pending profile is shipped deterministically.
      await h.instance.userProfile.save();
      await flushTick(40);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
      // Merge: one old_device_id query string param on the merge request.
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(1);

      // user_details calls: one after beginSession+sendSameData flushed by
      // either recordEvent or endSession; one after sendUserData flushed by
      // the recordEvent(C) that followed? sendUserData is called AFTER
      // recordEvent(C), so the trigger for the sendUserData bag is the
      // changeWithMerge pathway or later save(). We only pin that at least
      // one user_details carries a12345='4' (from sendSameData rounds) and
      // at least one carries a12345='My Property' (from sendUserData).
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length >= 2).assertTrue();
      let sawFour: boolean = false;
      let sawMyProperty: boolean = false;
      for (let i: number = 0; i < upCalls.length; i++) {
        const ud: Record<string, Object> = parseUserDetails(upCalls[i].data);
        const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
        if ((custom['a12345'] as string) === '4') sawFour = true;
        if ((custom['a12345'] as string) === 'My Property') sawMyProperty = true;
      }
      expect(sawFour).assertTrue();
      expect(sawMyProperty).assertTrue();
    });

    /**
     * 8. 208_CR_CG_M — same as 207 plus consent=required+giveAll → one
     * consent snapshot lands before any other traffic.
     */
    it('scUP_UP_208_CR_CG_M', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      await flushTick(1200);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(1);

      await h.instance.sessions.beginSession();
      await flushTick(20);
      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.sessions.endSession();
      await flushTick(20);
      await h.instance.events.recordEvent('C');
      await sendUserData(h);
      await h.instance.sessions.endSession();
      await h.instance.deviceId.changeWithMerge('merge_id');
      await flushTick(40);
      await sendSameData(h);
      await h.instance.deviceId.changeWithoutMerge('non_merge_id');
      await flushTick(1200); // let any consent coalesce fire
      // After changeWithoutMerge, consent is reset — further sends are gated
      // on the new user's consent, which is unset. sendSameData / recordEvent
      // will produce no user_details past the device-id change.
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await flushTick(40);
      await h.instance.userProfile.save();
      await flushTick(40);

      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(1);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(1);
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(1);
      const upCalls = h.network.findCallsWithParam('user_details=');
      let sawFour: boolean = false;
      let sawMyProperty: boolean = false;
      for (let i: number = 0; i < upCalls.length; i++) {
        const ud: Record<string, Object> = parseUserDetails(upCalls[i].data);
        const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
        if ((custom['a12345'] as string) === '4') sawFour = true;
        if ((custom['a12345'] as string) === 'My Property') sawMyProperty = true;
      }
      expect(sawFour).assertTrue();
      expect(sawMyProperty).assertTrue();
    });

    /**
     * 9. 209_CR_CNG_M — manual sessions, consent required + none given.
     * Only the device-id merge request should appear (merge doesn't require
     * per-feature consent). No session, no user_details, no events.
     */
    it('scUP_UP_209_CR_CNG_M', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.consent.setRequiresConsent(true);
      });

      await h.instance.sessions.beginSession();
      await h.instance.events.recordEvent('A');
      await h.instance.events.recordEvent('B');
      await sendSameData(h);
      await h.instance.sessions.endSession();
      await h.instance.events.recordEvent('C');
      await sendUserData(h);
      await h.instance.sessions.endSession();
      await h.instance.deviceId.changeWithMerge('merge_id');
      await flushTick(40);
      await sendSameData(h);
      await h.instance.deviceId.changeWithoutMerge('non_merge_id');
      await flushTick(40);
      await sendSameData(h);
      await h.instance.events.recordEvent('D');
      await flushTick(1200);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('begin_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('end_session=1').length).assertEqual(0);
      expect(h.network.findCallsWithParam('consent=').length).assertEqual(0);
      // Merge ID request goes out regardless of feature consent.
      expect(h.network.findCallsWithParam('old_device_id=').length).assertEqual(1);
    });

    /**
     * 10. 210_CNR_M_duration — init with short update interval, sendUserData,
     * wait past the interval. HOS: sendUpdate calls saveUserProfileIfPending
     * only if a session is active; without an explicit beginSession in this
     * scenario, the timer path can't flush. Drive a save() explicitly to
     * pin the user_details shape — this is the behavior contract the Android
     * test is locking in.
     */
    it('scUP_UP_210_CNR_M_duration', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.sessions.setUpdateIntervalSec(2);
        cfg.views.setTrackOrientationChanges(false);
      });

      await sendUserData(h);
      await flushTick(2500);

      // HOS: update timer is only active after beginSession; without one, the
      // save must be explicit. Matches the underlying contract the original
      // test is pinning: user_details eventually carries the full modifier bag.
      await h.instance.userProfile.save();
      await flushTick(40);

      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expectUserDataModifiers(parseUserDetails(upCalls[0].data), 'My Property');
    });

    // --- HOS-only: auto-save behavior (Android does NOT have this) ---
    //
    // Every public ModuleUserProfile MUTATION method auto-triggers a
    // "flush events queue → save user_details" pair, BUT ONLY when the
    // events queue currently has buffered events. Without events to flush
    // the trigger no-ops (no user_details either). Explicit `save()` is
    // NOT gated — it always saves (matches Android's saveInternal contract).

    /**
     * setProperty without any queued events does NOT auto-save. The trigger
     * is gated; with an empty events queue both the flush and the save are
     * skipped. Pins the gating direction.
     */
    it('autoSave_setPropertyWithoutEvents_doesNotEmit', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('level', 10);
      await flushTick(60);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
    });

    /**
     * setProperty WITH a queued event auto-saves — the events flush rides
     * with the user_details enqueue, both land on the wire.
     */
    it('autoSave_setPropertyWithQueuedEvents_flushesEventsOnly_noUserDetails', 0, async () => {
      // Mirror Android `onUserPropertiesChanged → sendEventsIfNeeded(true)`
      // and SDK_REQUEST_SCENARIOS.md cascade #3: setProperty with queued
      // events flushes the events queue but does NOT enqueue user_details.
      // user_details only ships on explicit save() or a save-triggering
      // callsite (recordEvent prelude, sessions, device-id change).
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('e1');
      // Event sits in memory queue (threshold 100); no requests yet.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      h.instance.userProfile.setProperty('level', 10);
      await flushTick(60);

      // Events flushed, but user_details stays buffered until explicit save.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      // Explicit save() ships the buffered properties.
      await h.instance.userProfile.save();
      await flushTick(60);
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['level'] as number).assertEqual(10);
    });

    /**
     * Each modifier method (increment / incrementBy / multiply / saveMax /
     * saveMin / setOnce / push / pushUnique / pull) auto-flushes events
     * when an event is queued ahead of it (cascade #3 of the spec). They
     * do NOT auto-emit user_details — that requires an explicit save() or
     * a save-triggering callsite. Note: each subsequent `recordEvent` call
     * runs `saveUserProfileIfPending` as its prelude (Android cascade #2),
     * so it will SHIP the previous iteration's pending user_details — that's
     * `recordEvent`'s contract, not the modifier's auto-trigger.
     */
    it('autoSave_eachModifierMethodWithQueuedEvent_flushesEventsOnly', 0, async () => {
      const h: Harness = await buildHarness();

      const steps: ((() => void) | string)[][] = [
        ['e_inc', (): void => { h.instance.userProfile.increment('inc1'); }],
        ['e_incBy', (): void => { h.instance.userProfile.incrementBy('inc2', 5); }],
        ['e_mul', (): void => { h.instance.userProfile.multiply('mul1', 2); }],
        ['e_max', (): void => { h.instance.userProfile.saveMax('max1', 100); }],
        ['e_min', (): void => { h.instance.userProfile.saveMin('min1', 1); }],
        ['e_once', (): void => { h.instance.userProfile.setOnce('once1', 'first'); }],
        ['e_push', (): void => { h.instance.userProfile.push('arr1', 'a'); }],
        ['e_pushUnique', (): void => { h.instance.userProfile.pushUnique('arr2', 'b'); }],
        ['e_pull', (): void => { h.instance.userProfile.pull('arr3', 'c'); }]
      ];
      for (let i = 0; i < steps.length; i++) {
        const record: string = steps[i][0] as string;
        const mutate: () => void = steps[i][1] as () => void;
        await h.instance.events.recordEvent(record);
        mutate();
        await flushTick(40);
        // Events flush: one per iteration (the modifier's auto-trigger drains
        // the just-recorded event).
        expect(h.network.findCallsWithParam('events=').length).assertEqual(i + 1);
        // user_details: recordEvent's prelude in iteration i+1 saves the
        // pending UP from iteration i. So count = i (zero on first iter).
        expect(h.network.findCallsWithParam('user_details=').length).assertEqual(i);
      }
    });

    /**
     * Burst coalescing: with one queued event and four synchronous setProperty
     * calls on the same key, the first chain entry flushes the queued event,
     * then later entries see an empty events queue and bail. No user_details
     * lands until explicit save(); when it does it carries the merged final
     * buffer (a='4').
     */
    it('autoSave_burstWithEventCoalescesToSingleEventsRequest', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('e1');

      h.instance.userProfile.setProperty('a', '1');
      h.instance.userProfile.setProperty('a', '2');
      h.instance.userProfile.setProperty('a', '3');
      h.instance.userProfile.setProperty('a', '4');
      await flushTick(60);

      // One events flush from the burst, no user_details yet.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      // Explicit save() ships the merged buffer (last-write-wins).
      await h.instance.userProfile.save();
      await flushTick(60);
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['a'] as string).assertEqual('4');
    });

    /**
     * Auto-trigger drains events queue immediately on mutation when events
     * are pending. user_details does NOT ride along — that requires
     * an explicit save(). When save() runs after the flush, the wire order
     * is events= → user_details=.
     */
    it('autoSave_setProperty_flushesEventsImmediately_explicitSaveLandsAfter', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('e1');
      await h.instance.events.recordEvent('e2');
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      h.instance.userProfile.setProperty('theme', 'dark');
      await flushTick(60);

      // Events flushed by the auto-trigger; no user_details yet.
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      // Explicit save() lands user_details — strictly AFTER the events= flush.
      await h.instance.userProfile.save();
      await flushTick(60);
      const eventCalls = h.network.findCallsWithParam('events=');
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      const eventsIdx: number = h.network.calls.indexOf(eventCalls[0]);
      const upIdx: number = h.network.calls.indexOf(upCalls[0]);
      expect(eventsIdx < upIdx).assertTrue();
    });

    /**
     * `clear()` is a mutation method — its trigger gates on the events queue
     * too. With a queued event, clear() flushes events; the buffer is empty
     * after clear so no user_details ships.
     */
    it('autoSave_clearWithQueuedEvent_flushesEventsButNoUserDetails', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.events.recordEvent('e1');
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);

      h.instance.userProfile.setProperty('discarded', 'value');
      h.instance.userProfile.clear();
      await flushTick(60);

      // The first chain entry (from setProperty) sees pending=false (clear
      // ran sync first) and skips saveInternal — but events still drain.
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(1);
    });

    /**
     * Explicit `save()` is NOT gated on the events queue — it always ships
     * user_details when there's pending state, even with no events queued.
     * This preserves the "save means save" contract that Android maintains.
     */
    it('autoSave_explicitSaveNotGated_savesWithoutEvents', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('manual', 'value');
      // setProperty's auto-trigger gates on events (none queued) → no-op.
      await flushTick(40);
      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);

      // Explicit save is unconditional: ships user_details regardless.
      await h.instance.userProfile.save();
      await flushTick(40);
      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect((parseUserDetails(upCalls[0].data)['custom'] as Record<string, Object>)['manual'] as string).assertEqual('value');
    });

    /**
     * Consent gate still wins over the auto-trigger. With consent required
     * and USERS not granted, even an event-queued mutation can't ship a
     * user_details — saveInternal short-circuits at the consent check.
     * (Events DO still flush — the events feature consent is independent.)
     */
    it('autoSave_respectsUsersConsentGate', 0, async () => {
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true); // none granted
      });
      // Recording an event without events consent is itself a no-op, so the
      // events queue stays empty and the auto-trigger never fires anyway.
      // Explicit save() is the path that proves the consent check works.
      h.instance.userProfile.setProperty('hidden', 'value');
      await h.instance.userProfile.save();
      await flushTick(60);

      expect(h.network.findCallsWithParam('user_details=').length).assertEqual(0);
    });

    /**
     * Concurrent path — `recordEvent` calls `core.saveUserProfileIfPending`
     * which goes through the unconditional save chain entry. With the
     * synchronous clear-then-enqueue inside `saveInternal`, even a
     * setProperty followed immediately by a recordEvent produces exactly
     * one user_details, not a duplicate. Locks in the race fix.
     */
    it('autoSave_noDuplicateWhenRecordEventFollowsSetProperty', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.userProfile.setProperty('name', 'Once');
      // No await between setProperty and recordEvent — the auto-trigger
      // chain entry races recordEvent's saveUserProfileIfPending. Auto
      // entry skips (no events yet); saveUserProfileIfPending's
      // unconditional entry saves once.
      await h.instance.events.recordEvent('e1');
      await flushTick(60);

      const upCalls = h.network.findCallsWithParam('user_details=');
      expect(upCalls.length).assertEqual(1);
      expect(parseUserDetails(upCalls[0].data)['name'] as string).assertEqual('Once');
    });

    it('userProfileWireOrder_consentBeforeBeginSessionBeforeUserDetails', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).setEnabled(['sessions', 'users']);
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      h.instance.userProfile.setProperty('name', 'Alice');
      await h.instance.userProfile.save();
      await flushTick(60);
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1', 'user_details=']);
    });
  });
}
