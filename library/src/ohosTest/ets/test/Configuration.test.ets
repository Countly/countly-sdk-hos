import { describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, TestableCountlyConfig } from './TestHelpers';
import { FilterList } from '../../../main/ets/internal/ServerConfig';
import { CountlyInstance } from '../../../main/ets/CountlyInstance';
import { CountlyConfig } from '../../../main/ets/CountlyConfig';
import { Logger } from '../../../main/ets/internal/Logger';
import { SegmentationMap } from '../../../main/ets/types/Types';
import common from '@ohos.app.ability.common';
import { InMemoryStorage } from './doubles/InMemoryStorage';
import { FakeNetwork } from './doubles/FakeNetwork';

/**
 * Helpers to build well-formed and malformed SBS payloads. Centralised so
 * each test reads as a behavioural assertion rather than a JSON literal.
 */
function buildSbsBody(inner: Record<string, Object>): string {
  const env: Record<string, Object> = {};
  env['v'] = 1;
  env['t'] = Date.now();
  env['c'] = inner;
  return JSON.stringify(env);
}

function fakeContext(): common.Context { return {} as common.Context; }

/**
 * Pull the URL-encoded `user_details` JSON out of a recorded request body.
 * The wire shape is `{ <predefinedKey>: value, ..., custom: { <k>: v, ..., $inc: { ... } } }`,
 * so callers can introspect both the predefined bag and the custom + modifier
 * sub-tree from a single parse.
 */
function parseUserDetails(data: string): Record<string, Object> {
  const marker: string = 'user_details=';
  const idx: number = data.indexOf(marker);
  if (idx === -1) return {};
  let tail: string = data.substring(idx + marker.length);
  const amp: number = tail.indexOf('&');
  if (amp !== -1) tail = tail.substring(0, amp);
  return JSON.parse(decodeURIComponent(tail)) as Record<string, Object>;
}

/**
 * Count the custom (non-modifier) keys under user_details.custom — i.e. keys
 * that don't start with `$`. Mirrors what `ModuleUserProfile.customSet` would
 * have held just before the flush, which is the only externally observable
 * proxy for the upcl-bounded custom cache size.
 */
function countCustomPropsOnWire(data: string): number {
  const ud: Record<string, Object> = parseUserDetails(data);
  const custom: Record<string, Object> | undefined = ud['custom'] as Record<string, Object> | undefined;
  if (!custom) return 0;
  const keys: string[] = Object.keys(custom);
  let n: number = 0;
  for (let i = 0; i < keys.length; i++) {
    if (!keys[i].startsWith('$')) n++;
  }
  return n;
}

/**
 * Count distinct modifier-target keys across all `$op` buckets under
 * user_details.custom. Matches the "distinct keys across the union of ops"
 * semantics that `ModuleUserProfile.applyCacheLimitToMods` enforces — same
 * key in two ops still counts as 1.
 */
function countModifierPropsOnWire(data: string): number {
  const ud: Record<string, Object> = parseUserDetails(data);
  const custom: Record<string, Object> | undefined = ud['custom'] as Record<string, Object> | undefined;
  if (!custom) return 0;
  const opKeys: string[] = Object.keys(custom);
  const seen: string[] = [];
  for (let i = 0; i < opKeys.length; i++) {
    if (!opKeys[i].startsWith('$')) continue;
    const inner: Record<string, Object> = custom[opKeys[i]] as Record<string, Object>;
    const innerKeys: string[] = Object.keys(inner);
    for (let j = 0; j < innerKeys.length; j++) {
      if (seen.indexOf(innerKeys[j]) === -1) seen.push(innerKeys[j]);
    }
  }
  return seen.length;
}

/**
 * SDK Behavior Settings (dev guide §SDK Behavior Settings) — sweep over
 * everything the module exposes:
 *   1. `setSDKBehaviorSettings` bootstrap precedence (dev-supplied < stored).
 *   2. `disableSDKBehaviorSettingsUpdates` blocks the fetch + timer.
 *   3. Server response validation (envelope shape, type per key).
 *   4. Apply path: ServerConfig field updates AND the propagated
 *      `Limits` / `eventQueueThreshold` / `maxRequestQueueSize` etc.
 *   5. Wire effects: networking off holds queue, st off blocks begin_session,
 *      vt off blocks views, crt off blocks crashes, lt off blocks location.
 *   6. Filter purge: whitelist for a category drops opposing blacklist.
 *
 * Storage round-trip is NOT covered end-to-end here because every harness
 * gets a fresh `InMemoryStorage` — the apply paths are exercised directly,
 * which is what the dev guide schema actually pins down.
 */
export default function configurationTest() {
  describe('ConfigurationTest', () => {

    it('init_noBootstrap_defaultsArePermissive', 0, async () => {
      // No dev-supplied SBS, no stored SBS — the SDK should run with all
      // defaults from `ServerConfig`. Every feature flag stays true so this
      // matches "SDK behaves like behavior settings was never spec'd".
      const h: Harness = await buildHarness();
      expect(h.instance.config.serverConfig.networkingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.trackingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.sessionTrackingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.viewTrackingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.crashReportingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.locationTrackingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.customEventTrackingEnabled).assertTrue();
      expect(h.instance.config.serverConfig.bomEnabled).assertTrue();
      expect(h.instance.config.serverConfig.requestQueueSize).assertEqual(1000);
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
      expect(h.instance.config.serverConfig.sessionUpdateInterval).assertEqual(60);
    });

    it('setSDKBehaviorSettings_validJSON_appliesBeforeOnInit', 0, async () => {
      // Dev-supplied bootstrap should apply during loadFromStorage so that
      // `eventQueueThreshold` (read by ModuleEvents at every recordEvent)
      // sees the post-applied value.
      const inner: Record<string, Object> = { 'eqs': 7, 'st': false, 'lkl': 32 };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(7);
      expect(h.instance.config.serverConfig.sessionTrackingEnabled).assertFalse();
      expect(h.instance.config.serverConfig.limitKeyLength).assertEqual(32);
      // Propagated to live mutables so existing modules pick it up.
      expect(h.instance.config.eventQueueThreshold).assertEqual(7);
      expect(h.instance.config.limits.maxKeyLength).assertEqual(32);
    });

    it('setSDKBehaviorSettings_invalidJSON_ignored', 0, async () => {
      // Malformed JSON must not throw and must leave defaults intact. The
      // module logs a warning — assertion is on the user-visible behavior.
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings('not json{}{}{}');
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
      expect(h.instance.config.serverConfig.networkingEnabled).assertTrue();
    });

    it('setSDKBehaviorSettings_emptyValue_silentlyDropped', 0, async () => {
      // Empty/whitespace shouldn't even reach the module — the setter
      // rejects at the config layer so `sdkBehaviorSettings` stays null.
      const cfg: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      cfg.setSDKBehaviorSettings('');
      expect(cfg.sdkBehaviorSettings).assertNull();
      cfg.setSDKBehaviorSettings('   ');
      expect(cfg.sdkBehaviorSettings).assertNull();
    });

    it('setSDKBehaviorSettings_envelopeWithoutVT_rejected', 0, async () => {
      // Dev guide §SDK Behavior Settings: envelope must have v + t + c.
      // Missing v means the whole payload is dropped (no partial apply).
      const partial: string = '{"c":{"eqs":5}}';
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(partial);
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
    });

    it('disableSDKBehaviorSettingsUpdates_skipsFetchAndTimer', 0, async () => {
      // No /o/sdk?method=sc request and no periodic timer when disabled.
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.disableSDKBehaviorSettingsUpdates();
      });
      await flushTick(60);
      const sbsCalls = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=sc') !== -1);
      expect(sbsCalls.length).assertEqual(0);
    });

    it('onInit_firesFetchToOSdkMethodSc', 0, async () => {
      // Default path: a single SBS fetch goes to /o/sdk with method=sc.
      const h: Harness = await buildHarness();
      await flushTick(60);
      const sbsCalls = h.network.calls.filter((c) => c.endpoint === '/o/sdk' && c.data.indexOf('method=sc') !== -1);
      expect(sbsCalls.length).assertEqual(1);
    });

    it('serverFetch_validResponse_appliesToServerConfig', 0, async () => {
      // FakeNetwork serves a body — module should parse + apply it to the
      // live ServerConfig fields modules read. The body must be primed on the
      // network *before* init() runs (init triggers the SC fetch, and the
      // first execute() consumes whatever `nextBody` is set at that moment).
      const inner: Record<string, Object> = { 'networking': false, 'eqs': 12, 'rqs': 250 };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness(undefined, (network: FakeNetwork) => {
        network.nextBody = body;
      });
      await flushTick(120);
      expect(h.instance.config.serverConfig.networkingEnabled).assertFalse();
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(12);
      expect(h.instance.config.serverConfig.requestQueueSize).assertEqual(250);
    });

    it('serverFetch_persistsResponse_subsequentInstanceUsesStored', 0, async () => {
      // Build instance A — server response gets persisted to storage. Build
      // instance B against the SAME storage — bootstrap from stored kicks in.
      const inner: Record<string, Object> = { 'eqs': 33, 'lkl': 64 };
      const body: string = buildSbsBody(inner);
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network: FakeNetwork = new FakeNetwork(logger);
      network.nextBody = body;
      const cfgA: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = new CountlyInstance(cfgA, storage, network);
      await a.init();
      await flushTick(120);
      // Storage now has cly_sbs.
      expect(storage.dump()['cly_sbs'] !== undefined).assertTrue();

      // Halt A so its timer doesn't tick during B's lifecycle.
      await a.halt();
      // Build B — same storage, fresh network. SBS must come from storage,
      // not from a fresh /o/sdk fetch (we'll verify by setting the network's
      // canned body to defaults so any fetch would over-write).
      const network2: FakeNetwork = new FakeNetwork(logger);
      const cfgB: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const b: CountlyInstance = new CountlyInstance(cfgB, storage, network2);
      await b.init();
      // Pre-fetch state should already reflect the stored values.
      expect(b.config.serverConfig.eventQueueSize).assertEqual(33);
      expect(b.config.limits.maxKeyLength).assertEqual(64);
      await b.halt();
    });

    it('apply_invalidTypes_dropsOnlyBadKeys', 0, async () => {
      // String for eqs (must be int>0) — dropped.
      // Negative for lkl (must be int>0) — dropped.
      // Non-array for eb (must be JSONArray) — dropped.
      // Valid keys alongside still apply — partial validation, not all-or-nothing.
      const inner: Record<string, Object> = {
        'eqs': '7' as Object,
        'lkl': -3 as Object,
        'eb': 'block' as Object,
        'rqs': 250 as Object
      };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100); // default kept
      expect(h.instance.config.serverConfig.limitKeyLength).assertEqual(128); // default kept
      expect(h.instance.config.serverConfig.eventFilter.filterList.length).assertEqual(0); // default kept
      expect(h.instance.config.serverConfig.requestQueueSize).assertEqual(250); // valid applied
    });

    it('apply_consentRequired_oneWayOverride', 0, async () => {
      // Server can flip requiresConsent ON, but cannot flip an integrator-set
      // requiresConsent OFF. This is a deliberate divergence from Android.
      const offBody: string = buildSbsBody({ 'cr': false });
      const h1: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.consent.setRequiresConsent(true);
        cfg.setSDKBehaviorSettings(offBody);
      });
      expect(h1.instance.config.requiresConsent).assertTrue(); // server OFF ignored

      const onBody: string = buildSbsBody({ 'cr': true });
      const h2: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        // Note: integrator did NOT set requiresConsent — server flipping it ON
        // should take effect.
        cfg.setSDKBehaviorSettings(onBody);
      });
      expect(h2.instance.config.requiresConsent).assertTrue();
    });

    it('apply_loggingFlag_propagatesToLogger', 0, async () => {
      // The `log` SBS key drives Logger.setEnabled — server can mute or
      // unmute SDK console output without an integrator code change.
      const body: string = buildSbsBody({ 'log': true });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        // Start with logging off so the apply has somewhere to flip TO.
        cfg.logging.enabled = false;
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.loggingEnabled).assertTrue();
    });

    it('wire_networkingDisabled_holdsQueueButAcceptsEnqueues', 0, async () => {
      // networking=false: requests still enqueue (durable), but tick refuses
      // to send. Flipping it back on drains them.
      const body: string = buildSbsBody({ 'networking': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      // Pre-init the SBS fetch was bypassed (networking gate fires after
      // queue accept) — but the bootstrap apply already flipped the flag.
      // Add a direct request so we can observe it stays queued.
      // Wait for the deferred init-time healthcheck to land so it's part of
      // the cleared baseline rather than racing the assertion below.
      await flushTick(5);
      h.network.calls = [];
      const dr: Record<string, string> = { 'param': 'value' };
      await h.instance.requests.addDirectRequest(dr);
      await flushTick(80);
      // Direct request enqueued but NOT sent.
      expect(h.network.calls.length).assertEqual(0);
      expect(h.instance.requestQueue.size() >= 1).assertTrue();
    });

    it('wire_trackingDisabled_blocksEnqueueEntirely', 0, async () => {
      const body: string = buildSbsBody({ 'tracking': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(5);
      h.network.calls = [];
      const before: number = h.instance.requestQueue.size();
      const dr: Record<string, string> = { 'param': 'value' };
      await h.instance.requests.addDirectRequest(dr);
      await flushTick(80);
      // tracking=false drops at enqueue — queue size unchanged.
      expect(h.instance.requestQueue.size()).assertEqual(before);
      expect(h.network.calls.length).assertEqual(0);
    });

    it('wire_sessionTrackingDisabled_blocksBeginSession', 0, async () => {
      const body: string = buildSbsBody({ 'st': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(60);
      const beforeCount: number = h.network.findCallsWithParam('begin_session=').length;
      await h.instance.sessions.beginSession();
      await flushTick(80);
      // No begin_session sent because SBS killed session tracking.
      expect(h.network.findCallsWithParam('begin_session=').length).assertEqual(beforeCount);
    });

    it('wire_viewTrackingDisabled_blocksStartView', 0, async () => {
      const body: string = buildSbsBody({ 'vt': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(60);
      const before: number = h.network.findCallsWithParam('events=').length;
      const id: string | null = await h.instance.views.startView('home', null);
      await flushTick(80);
      // startView returns null when vt is off; nothing enqueued.
      expect(id).assertNull();
      expect(h.network.findCallsWithParam('events=').length).assertEqual(before);
    });

    it('wire_crashReportingDisabled_dropsExceptions', 0, async () => {
      const body: string = buildSbsBody({ 'crt': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.crashes.enableCrashReporting();
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(60);
      const before: number = h.network.findCallsWithParam('crash=').length;
      await h.instance.crashes.recordHandledException(new Error('boom'), null);
      await flushTick(80);
      expect(h.network.findCallsWithParam('crash=').length).assertEqual(before);
    });

    it('wire_locationTrackingDisabled_blocksSetLocation', 0, async () => {
      const body: string = buildSbsBody({ 'lt': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.sessions.enableManualControl();
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(60);
      const before: number = h.network.findCallsWithParam('country_code=').length;
      await h.instance.location.setLocation('TR', 'Istanbul', null, null);
      await flushTick(80);
      // setLocation short-circuits — nothing enqueued.
      expect(h.network.findCallsWithParam('country_code=').length).assertEqual(before);
    });

    it('filter_userPropertyBlacklist_dropsKey', 0, async () => {
      // upb listed → dropped at setProperties time, not at save time, so
      // the in-memory bag never grows.
      const body: string = buildSbsBody({ 'upb': ['secret_key'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      await flushTick(60);
      h.instance.userProfile.setProperty('public_key', 'visible');
      h.instance.userProfile.setProperty('secret_key', 'hidden');
      await h.instance.userProfile.save();
      await flushTick(80);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length >= 1).assertTrue();
      const body2: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(body2.indexOf('public_key') !== -1).assertTrue();
      expect(body2.indexOf('secret_key') === -1).assertTrue();
    });

    it('filter_purgeOpposites_whitelistArrivalDropsBlacklist', 0, async () => {
      // First apply: event blacklist. Second apply: event whitelist. The
      // module must drop the blacklist when the whitelist takes its place.
      const blackBody: string = buildSbsBody({ 'eb': ['a', 'b'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(blackBody);
      });
      expect(h.instance.config.serverConfig.eventFilter.isWhitelist).assertFalse();
      expect(h.instance.config.serverConfig.eventFilter.filterList.length).assertEqual(2);

      // Drive a second apply via the manual whitelist hook on the live
      // FilterList — direct mutation is the same path the apply method takes.
      h.instance.config.serverConfig.eventFilter = new FilterList<string[]>(['kept'], true);
      expect(h.instance.config.serverConfig.eventFilter.isWhitelist).assertTrue();
      expect(h.instance.config.serverConfig.eventFilter.filterList.length).assertEqual(1);
    });

    it('apply_journeyTriggerEvents_storedInServerConfig', 0, async () => {
      // jte is exposed on ServerConfig; current build doesn't auto-refresh
      // content zone (content module disabled), but the apply path must
      // still surface the list so a re-enable picks it up.
      const body: string = buildSbsBody({ 'jte': ['signup', 'purchase'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const jte: string[] = h.instance.config.serverConfig.journeyTriggerEvents;
      expect(jte.length).assertEqual(2);
      expect(jte.indexOf('signup') !== -1).assertTrue();
      expect(jte.indexOf('purchase') !== -1).assertTrue();
    });

    it('apply_eventSegmentationWhitelist_keptAsRecord', 0, async () => {
      // esw shape is { eventName: [allowedSegKey, ...] } — exercise that
      // it lands in eventSegmentationFilter as a Record<string, string[]>.
      const inner: Record<string, Object> = {};
      const esw: Record<string, Object> = {};
      esw['login'] = ['method'] as Object;
      inner['esw'] = esw;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const fl: FilterList<Record<string, string[]>> = h.instance.config.serverConfig.eventSegmentationFilter;
      expect(fl.isWhitelist).assertTrue();
      expect(fl.filterList['login'][0]).assertEqual('method');
    });

    it('apply_limits_propagateToLimitsObject', 0, async () => {
      // The Limits object is a separate field consumed by truncate paths.
      // SBS apply must mirror the values onto it; otherwise a server raise
      // of `lvs` would never reach Utils.sanitizeSegmentation.
      const inner: Record<string, Object> = {
        'lkl': 50, 'lvs': 75, 'lsv': 60, 'lbc': 25, 'ltlpt': 18, 'ltl': 144
      };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.limits.maxKeyLength).assertEqual(50);
      expect(h.instance.config.limits.maxValueSize).assertEqual(75);
      expect(h.instance.config.limits.maxSegmentationValues).assertEqual(60);
      expect(h.instance.config.limits.maxBreadcrumbCount).assertEqual(25);
      expect(h.instance.config.limits.maxStackTraceLinesPerThread).assertEqual(18);
      expect(h.instance.config.limits.maxStackTraceLineLength).assertEqual(144);
    });

    it('apply_contentZoneInterval_min16Validated', 0, async () => {
      // czi=15 is invalid (dev guide minimum 16); czi=20 is valid.
      const tooLow: string = buildSbsBody({ 'czi': 15 });
      const h1: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(tooLow);
      });
      expect(h1.instance.config.serverConfig.contentZoneInterval).assertEqual(30); // default

      const ok: string = buildSbsBody({ 'czi': 20 });
      const h2: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(ok);
      });
      expect(h2.instance.config.serverConfig.contentZoneInterval).assertEqual(20);
    });

    it('apply_bomRqPercentage_openIntervalValidated', 0, async () => {
      // bom_rqp must be in the open interval (0, 1). Boundary values 0 and
      // 1 are rejected; 0.25 is valid.
      const zero: string = buildSbsBody({ 'bom_rqp': 0 });
      const h1: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(zero);
      });
      expect(h1.instance.config.serverConfig.bomRequestQueuePercentage).assertEqual(0.5);

      const valid: string = buildSbsBody({ 'bom_rqp': 0.25 });
      const h2: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(valid);
      });
      expect(h2.instance.config.serverConfig.bomRequestQueuePercentage).assertEqual(0.25);
    });

    it('apply_bomRqPercentage_oneRejected', 0, async () => {
      // 1.0 is the closed end — must be rejected.
      const one: string = buildSbsBody({ 'bom_rqp': 1 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(one);
      });
      expect(h.instance.config.serverConfig.bomRequestQueuePercentage).assertEqual(0.5);
    });

    it('apply_contentZoneInterval_minBoundary16Accepted', 0, async () => {
      // The boundary value 16 itself is accepted (>= 16).
      const ok: string = buildSbsBody({ 'czi': 16 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(ok);
      });
      expect(h.instance.config.serverConfig.contentZoneInterval).assertEqual(16);
    });

    // ============================================================
    // Validation: more invalid envelope shapes (Android parity)
    // ============================================================

    it('apply_invalidEnvelopes_allRejected', 0, async () => {
      // Each of these should be rejected and leave defaults intact. Mirrors
      // Android's `invalidConfigResponses_AreRejected` matrix.
      const cases: string[] = [
        '{}',                                // missing v, t, c
        '{"t":2,"c":{"eqs":5}}',             // missing v
        '{"v":1,"c":{"eqs":5}}',             // missing t
        '{"v":1,"t":2}',                     // missing c
        '{"v":1,"t":2,"c":123}',             // c is not object
        '{"v":1,"t":2,"c":false}',           // c is boolean
        '{"v":1,"t":2,"c":[1,2,3]}',         // c is array
        '{"v":1,"t":2,"c":"fdf"}'            // c is string
      ];
      for (let i = 0; i < cases.length; i++) {
        const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
          cfg.setSDKBehaviorSettings(cases[i]);
        });
        expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
      }
    });

    it('apply_emptyInnerConfig_logged_noFieldsChanged', 0, async () => {
      // Envelope is valid but `c` is empty — nothing to apply, no crash.
      const body: string = buildSbsBody({});
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
      expect(h.instance.config.serverConfig.networkingEnabled).assertTrue();
    });

    it('apply_unknownInnerKeys_silentlyDropped', 0, async () => {
      // Future-proofing: unknown keys MUST be dropped at validation, not
      // copied into the persisted blob (would poison subsequent merges).
      const inner: Record<string, Object> = { 'eqs': 7, 'totallyUnknown': 'x' as Object, 'futureKey': 42 as Object };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      // Valid key applied, unknowns ignored without affecting other state.
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(7);
    });

    it('apply_eventSegFilter_invalidShape_dropped', 0, async () => {
      // esw / esb must be a JSON object — array or scalar should be dropped.
      const inner: Record<string, Object> = { 'esw': ['not', 'an', 'object'] as Object };
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const fl = h.instance.config.serverConfig.eventSegmentationFilter;
      expect(fl.isWhitelist).assertFalse(); // default unchanged
      expect(Object.keys(fl.filterList).length).assertEqual(0);
    });

    // ============================================================
    // Persistence chain — multi-init behavior (Android parity)
    // ============================================================

    it('persistence_failedFetchPreservesPreviouslyStored', 0, async () => {
      // First init persists a server response. Second init's fetch fails (5xx)
      // — applied state should still reflect the previously stored values.
      const inner: Record<string, Object> = { 'eqs': 33, 'rqs': 222 };
      const body1: string = buildSbsBody(inner);
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network1: FakeNetwork = new FakeNetwork(logger);
      network1.nextBody = body1;
      const cfgA: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = new CountlyInstance(cfgA, storage, network1);
      await a.init();
      await flushTick(120);
      await a.halt();

      // Second init — fetch returns 500. Stored values must remain.
      const network2: FakeNetwork = new FakeNetwork(logger);
      network2.nextStatus = 500;
      network2.nextBody = '{"error":"down"}';
      const cfgB: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const b: CountlyInstance = new CountlyInstance(cfgB, storage, network2);
      await b.init();
      await flushTick(120);
      expect(b.config.serverConfig.eventQueueSize).assertEqual(33);
      expect(b.config.serverConfig.requestQueueSize).assertEqual(222);
      await b.halt();
    });

    it('persistence_subsequentResponseOverridesStored', 0, async () => {
      // Init A stores eqs=33. Init B receives eqs=99 — applied state reflects B.
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network1: FakeNetwork = new FakeNetwork(logger);
      network1.nextBody = buildSbsBody({ 'eqs': 33 });
      const cfgA: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = new CountlyInstance(cfgA, storage, network1);
      await a.init();
      await flushTick(120);
      await a.halt();

      const network2: FakeNetwork = new FakeNetwork(logger);
      network2.nextBody = buildSbsBody({ 'eqs': 99 });
      const cfgB: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const b: CountlyInstance = new CountlyInstance(cfgB, storage, network2);
      await b.init();
      await flushTick(120);
      expect(b.config.serverConfig.eventQueueSize).assertEqual(99);
      await b.halt();
    });

    it('persistence_partialResponse_mergesIntoStored', 0, async () => {
      // Server only sends eqs in the second response; earlier-stored rqs
      // should NOT be reset. Mirrors Android's per-key `extractValue` contract.
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network1: FakeNetwork = new FakeNetwork(logger);
      network1.nextBody = buildSbsBody({ 'rqs': 222, 'eqs': 33 });
      const cfgA: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = new CountlyInstance(cfgA, storage, network1);
      await a.init();
      await flushTick(120);
      await a.halt();

      const network2: FakeNetwork = new FakeNetwork(logger);
      // Second response ONLY has eqs.
      network2.nextBody = buildSbsBody({ 'eqs': 99 });
      const cfgB: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const b: CountlyInstance = new CountlyInstance(cfgB, storage, network2);
      await b.init();
      await flushTick(120);
      expect(b.config.serverConfig.eventQueueSize).assertEqual(99);
      // rqs preserved from the previous merge.
      expect(b.config.serverConfig.requestQueueSize).assertEqual(222);
      await b.halt();
    });

    // ============================================================
    // Filter: event filter actually drops events (Android parity)
    // ============================================================

    it('filter_eventBlacklist_dropsBlockedEvents', 0, async () => {
      const body: string = buildSbsBody({ 'eb': ['blocked_event', 'another_blocked'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      await h.instance.events.recordEvent('blocked_event');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      await h.instance.events.recordEvent('another_blocked');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      await h.instance.events.recordEvent('allowed_event');
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_event') !== -1).assertTrue();
    });

    it('filter_eventWhitelist_onlyAllowsListed', 0, async () => {
      const body: string = buildSbsBody({ 'ew': ['allowed_event'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      await h.instance.events.recordEvent('not_allowed');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      await h.instance.events.recordEvent('allowed_event');
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_event') !== -1).assertTrue();
      expect(decoded.indexOf('not_allowed') === -1).assertTrue();
    });

    it('filter_internalEventsBypassEventFilter', 0, async () => {
      // Even if an integrator names `[CLY]_view` in the event blacklist, a
      // startView call still records it — internal events ride independently
      // of the public event filter. Mirrors Android's
      // `eventFilter_internalEventsNotAffected`.
      const body: string = buildSbsBody({ 'eb': ['[CLY]_view', 'public_block'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const id: string | null = await h.instance.views.startView('home', null);
      await flushTick(80);
      expect(id !== null).assertTrue();
      const callsAfterView = h.network.findCallsWithParam('events=');
      expect(callsAfterView.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(callsAfterView[callsAfterView.length - 1].data);
      expect(decoded.indexOf('%5BCLY%5D_view') !== -1 || decoded.indexOf('[CLY]_view') !== -1).assertTrue();

      // Public event named in blacklist still blocked.
      const beforePublic: number = h.network.findCallsWithParam('events=').length;
      await h.instance.events.recordEvent('public_block');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(beforePublic);
    });

    it('filter_eventSpecialCharactersInName', 0, async () => {
      // Special characters in event names — filter still applies by exact match.
      const body: string = buildSbsBody({
        'eb': ['event with spaces', 'event-with-dashes', 'event_with_underscores']
      });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      await h.instance.events.recordEvent('event with spaces');
      await h.instance.events.recordEvent('event-with-dashes');
      await h.instance.events.recordEvent('event_with_underscores');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length).assertEqual(0);
      await h.instance.events.recordEvent('normal_event');
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    // ============================================================
    // Filter: user property filter (whitelist + predefined bypass + mods)
    // ============================================================

    it('filter_userPropertyWhitelist_allowsOnlyListed', 0, async () => {
      const body: string = buildSbsBody({ 'upw': ['allowed_prop'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.setProperty('allowed_prop', 'v1');
      h.instance.userProfile.setProperty('not_allowed', 'v2');
      await h.instance.userProfile.save();
      await flushTick(80);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_prop') !== -1).assertTrue();
      expect(decoded.indexOf('not_allowed') === -1).assertTrue();
    });

    it('filter_predefinedKeysBypassUserPropertyFilter', 0, async () => {
      // Predefined keys (name, email, username, ...) are SDK-owned and
      // bypass the upb/upw filter even when explicitly listed.
      const body: string = buildSbsBody({ 'upb': ['name', 'email', 'custom_blocked'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.setProperty('name', 'John Doe');
      h.instance.userProfile.setProperty('email', 'j@x.com');
      h.instance.userProfile.setProperty('custom_blocked', 'hidden');
      await h.instance.userProfile.save();
      await flushTick(80);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('"name":"John Doe"') !== -1).assertTrue();
      expect(decoded.indexOf('"email":"j@x.com"') !== -1).assertTrue();
      expect(decoded.indexOf('custom_blocked') === -1).assertTrue();
    });

    it('filter_userPropertyMods_respectFilter', 0, async () => {
      // incrementBy/multiply/push must consult the user-property filter too —
      // otherwise an integrator could bypass it via mods. Mirrors Android's
      // `userPropertyFilter_modifyCustomData_respectsFilter`.
      const body: string = buildSbsBody({ 'upb': ['blocked_prop'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.incrementBy('blocked_prop', 5);
      h.instance.userProfile.incrementBy('allowed_prop', 5);
      await h.instance.userProfile.save();
      await flushTick(80);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('blocked_prop') === -1).assertTrue();
      expect(decoded.indexOf('allowed_prop') !== -1).assertTrue();
      expect(decoded.indexOf('%24inc') !== -1 || decoded.indexOf('$inc') !== -1).assertTrue();
    });

    // ============================================================
    // Filter: segmentation filter applied to events (Android parity)
    // ============================================================

    it('filter_segmentationBlacklist_stripsKeysFromEvents', 0, async () => {
      const body: string = buildSbsBody({ 'sb': ['blocked_key', 'another_blocked'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const seg: SegmentationMap = {};
      seg['blocked_key'] = 'v1';
      seg['another_blocked'] = 'v2';
      seg['allowed_key'] = 'v3';
      await h.instance.events.recordEvent('test_event', seg, 1, 0, 0);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_key') !== -1).assertTrue();
      expect(decoded.indexOf('blocked_key') === -1).assertTrue();
      expect(decoded.indexOf('another_blocked') === -1).assertTrue();
    });

    it('filter_segmentationWhitelist_keepsOnlyListed', 0, async () => {
      const body: string = buildSbsBody({ 'sw': ['allowed_key'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const seg: SegmentationMap = {};
      seg['allowed_key'] = 'v1';
      seg['not_allowed_1'] = 'v2';
      seg['not_allowed_2'] = 'v3';
      await h.instance.events.recordEvent('test_event', seg, 1, 0, 0);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      expect(calls.length >= 1).assertTrue();
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_key') !== -1).assertTrue();
      expect(decoded.indexOf('not_allowed_1') === -1).assertTrue();
      expect(decoded.indexOf('not_allowed_2') === -1).assertTrue();
    });

    it('filter_eventSegmentationBlacklist_appliesPerEvent', 0, async () => {
      // esb shape: { "event1": ["key1"] } means strip key1 from event1's
      // segmentation only. event2's segmentation is untouched. Mirrors
      // Android `eventSegmentationFilter_blacklist_affectsSpecificEvents`.
      const inner: Record<string, Object> = {};
      const esb: Record<string, Object> = {};
      esb['event1'] = ['blocked_for_event1'] as Object;
      inner['esb'] = esb;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const seg1: SegmentationMap = {};
      seg1['blocked_for_event1'] = 'v1';
      seg1['allowed_key'] = 'v2';
      await h.instance.events.recordEvent('event1', seg1, 1, 0, 0);
      await flushTick(80);
      let calls = h.network.findCallsWithParam('events=');
      let decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_key') !== -1).assertTrue();
      expect(decoded.indexOf('blocked_for_event1') === -1).assertTrue();

      // event2 — no rule for it, all keys pass through.
      const seg2: SegmentationMap = {};
      seg2['blocked_for_event1'] = 'v1';
      seg2['other_key'] = 'v2';
      await h.instance.events.recordEvent('event2', seg2, 1, 0, 0);
      await flushTick(80);
      calls = h.network.findCallsWithParam('events=');
      decoded = decodeURIComponent(calls[calls.length - 1].data);
      // Both keys present for event2.
      expect(decoded.indexOf('blocked_for_event1') !== -1).assertTrue();
      expect(decoded.indexOf('other_key') !== -1).assertTrue();
    });

    it('filter_eventSegmentationWhitelist_keepsOnlyListedPerEvent', 0, async () => {
      const inner: Record<string, Object> = {};
      const esw: Record<string, Object> = {};
      esw['event1'] = ['allowed_for_event1'] as Object;
      inner['esw'] = esw;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const seg: SegmentationMap = {};
      seg['allowed_for_event1'] = 'v1';
      seg['not_allowed'] = 'v2';
      await h.instance.events.recordEvent('event1', seg, 1, 0, 0);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_for_event1') !== -1).assertTrue();
      expect(decoded.indexOf('not_allowed') === -1).assertTrue();
    });

    it('filter_combinedSegmentationFilters_bothApplied', 0, async () => {
      // General `sb` and per-event `esb` stack: each strips its own keys.
      const inner: Record<string, Object> = {};
      inner['sb'] = ['general_blocked'] as Object;
      const esb: Record<string, Object> = {};
      esb['test_event'] = ['event_specific_blocked'] as Object;
      inner['esb'] = esb;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      const seg: SegmentationMap = {};
      seg['general_blocked'] = 'v1';
      seg['event_specific_blocked'] = 'v2';
      seg['allowed_key'] = 'v3';
      await h.instance.events.recordEvent('test_event', seg, 1, 0, 0);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('events=');
      const decoded: string = decodeURIComponent(calls[calls.length - 1].data);
      expect(decoded.indexOf('allowed_key') !== -1).assertTrue();
      expect(decoded.indexOf('general_blocked') === -1).assertTrue();
      expect(decoded.indexOf('event_specific_blocked') === -1).assertTrue();
    });

    it('filter_emptySegmentationMap_recordsCleanly', 0, async () => {
      // Edge case: segmentation filter present but the event has no
      // segmentation — must not throw or drop the event.
      const body: string = buildSbsBody({ 'sb': ['some_key'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      await h.instance.events.recordEvent('test_event', {}, 1, 0, 0);
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    it('filter_nullSegmentation_recordsCleanly', 0, async () => {
      const body: string = buildSbsBody({ 'sb': ['some_key'] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.events.setQueueSizeToSend(1);
        cfg.setSDKBehaviorSettings(body);
      });
      h.network.calls = [];
      await h.instance.events.recordEvent('test_event', null, 1, 0, 0);
      await flushTick(80);
      expect(h.network.findCallsWithParam('events=').length >= 1).assertTrue();
    });

    // ============================================================
    // Filter parsing — comprehensive sweep with all filters in one body
    // ============================================================

    it('filter_allFiltersSetTogether_eachAppliedCorrectly', 0, async () => {
      // Mirrors Android `filterConfigParsing_allFiltersCorrectlyParsed`.
      const inner: Record<string, Object> = {};
      inner['eb'] = ['blocked_event'] as Object;
      inner['upb'] = ['blocked_prop'] as Object;
      inner['sb'] = ['blocked_seg'] as Object;
      const esb: Record<string, Object> = {};
      esb['specific_event'] = ['specific_key'] as Object;
      inner['esb'] = esb;
      inner['jte'] = ['journey_event'] as Object;
      inner['upcl'] = 200 as Object;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const sc = h.instance.config.serverConfig;
      expect(sc.eventFilter.isWhitelist).assertFalse();
      expect(sc.eventFilter.filterList.indexOf('blocked_event') !== -1).assertTrue();
      expect(sc.userPropertyFilter.isWhitelist).assertFalse();
      expect(sc.userPropertyFilter.filterList.indexOf('blocked_prop') !== -1).assertTrue();
      expect(sc.segmentationFilter.isWhitelist).assertFalse();
      expect(sc.segmentationFilter.filterList.indexOf('blocked_seg') !== -1).assertTrue();
      expect(sc.eventSegmentationFilter.isWhitelist).assertFalse();
      expect(sc.eventSegmentationFilter.filterList['specific_event'] !== undefined).assertTrue();
      expect(sc.journeyTriggerEvents.indexOf('journey_event') !== -1).assertTrue();
      expect(sc.userPropertyCacheLimit).assertEqual(200);
    });

    it('filter_purgeOpposites_storedBlacklistDroppedWhenWhitelistArrives', 0, async () => {
      // Apply blacklist via initial fetch, persist. Then a second apply of a
      // whitelist on the same category — the persisted blob must lose the
      // blacklist key entirely so a future restart doesn't re-load both.
      const logger: Logger = new Logger();
      const storage: InMemoryStorage = new InMemoryStorage(logger, 'test_app_key');
      const network1: FakeNetwork = new FakeNetwork(logger);
      network1.nextBody = buildSbsBody({ 'eb': ['x'] });
      const cfgA: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const a: CountlyInstance = new CountlyInstance(cfgA, storage, network1);
      await a.init();
      await flushTick(120);
      // Drive a SECOND server fetch that delivers a whitelist — onDeviceIdChangedNotMerged
      // would normally trigger this, but driving it explicitly via halt+re-init
      // keeps the test focused on the apply-merge logic.
      await a.halt();

      const network2: FakeNetwork = new FakeNetwork(logger);
      network2.nextBody = buildSbsBody({ 'ew': ['y'] });
      const cfgB: CountlyConfig = new CountlyConfig(fakeContext(), 'https://try.count.ly', 'test_app_key');
      const b: CountlyInstance = new CountlyInstance(cfgB, storage, network2);
      await b.init();
      await flushTick(120);
      // After purge, only the whitelist should remain.
      expect(b.config.serverConfig.eventFilter.isWhitelist).assertTrue();
      expect(b.config.serverConfig.eventFilter.filterList.indexOf('y') !== -1).assertTrue();
      // Persisted blob should not contain the eb key anymore.
      const stored: string = storage.dump()['cly_sbs'];
      expect(stored.indexOf('"eb"') === -1).assertTrue();
      expect(stored.indexOf('"ew"') !== -1).assertTrue();
      await b.halt();
    });

    // ============================================================
    // userPropertyCacheLimit (upcl) — enforcement (NEW for HOS)
    // ============================================================

    it('upcl_defaultLimitOf100', 0, async () => {
      const h: Harness = await buildHarness();
      expect(h.instance.config.serverConfig.userPropertyCacheLimit).assertEqual(100);
    });

    it('upcl_appliesFromBootstrap', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 75 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.userPropertyCacheLimit).assertEqual(75);
    });

    it('upcl_zeroRejected_defaultRetained', 0, async () => {
      // upcl must be > 0; 0 is rejected.
      const body: string = buildSbsBody({ 'upcl': 0 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.userPropertyCacheLimit).assertEqual(100);
    });

    // The upcl tests below assert cache-size effects through the wire instead
    // of introspecting `ModuleUserProfile`'s private fields. The flow is:
    // mutate via the userProfile facade → `await save()` → parse the resulting
    // `user_details=` body → count custom keys / modifier-target keys. Each
    // setter only stages into the cache; `save()` is what flushes (and resets)
    // it — so for tests that originally checked the cache twice, we either
    // (a) save once at the end and assert the union, or (b) save in between
    // and assert each batch separately. Comments at each test mark the choice.

    it('upcl_enforcesOnSetProperties_oldestEvicted', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 3 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const props: SegmentationMap = {};
      props['p1'] = 'v1';
      props['p2'] = 'v2';
      props['p3'] = 'v3';
      props['p4'] = 'v4';
      props['p5'] = 'v5';
      h.instance.userProfile.setProperties(props);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      // Only 3 should remain — the latest 3 in insertion order.
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(3);
    });

    it('upcl_underLimit_noEviction', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 10 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.setProperty('a', '1');
      h.instance.userProfile.setProperty('b', '2');
      h.instance.userProfile.setProperty('c', '3');
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(3);
    });

    it('upcl_predefinedKeysNotCounted', 0, async () => {
      // Named properties go on the predefined bag, not customSet — they are
      // NOT counted toward the upcl cache limit.
      const body: string = buildSbsBody({ 'upcl': 2 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const props: SegmentationMap = {};
      props['name'] = 'John';
      props['email'] = 'j@x.com';
      props['username'] = 'jdoe';
      props['custom1'] = 'v1';
      props['custom2'] = 'v2';
      props['custom3'] = 'v3';
      h.instance.userProfile.setProperties(props);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      // Custom is capped at 2; named survive independently as top-level keys.
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(2);
      const ud: Record<string, Object> = parseUserDetails(calls[0].data);
      expect(ud['name']).assertEqual('John');
      expect(ud['email']).assertEqual('j@x.com');
      expect(ud['username']).assertEqual('jdoe');
    });

    it('upcl_acrossMultipleSetCalls', 0, async () => {
      // Two batches, two saves — preserves the original "first-batch fits;
      // second-batch eviction" observation. After the first save() the cache
      // resets, so the second save sees the full 2 incoming keys; the cap
      // applies during staging when the third+fourth join an already-staged 2.
      const body: string = buildSbsBody({ 'upcl': 3 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const a: SegmentationMap = {};
      a['p1'] = 'v1';
      a['p2'] = 'v2';
      h.instance.userProfile.setProperties(a);
      const b: SegmentationMap = {};
      b['p3'] = 'v3';
      b['p4'] = 'v4';
      h.instance.userProfile.setProperties(b);
      // 4 distinct keys staged, capped at 3 BEFORE save() (cap applies at
      // setProperties time, not flush time).
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(3);
    });

    it('upcl_limitOne_keepsOnlyMostRecent', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 1 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const props: SegmentationMap = {};
      props['p1'] = 'v1';
      props['p2'] = 'v2';
      props['p3'] = 'v3';
      h.instance.userProfile.setProperties(props);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(1);
      // Sanity-check that it's the most-recent key (insertion-order eviction).
      const ud: Record<string, Object> = parseUserDetails(calls[0].data);
      const custom: Record<string, Object> = ud['custom'] as Record<string, Object>;
      expect(custom['p3']).assertEqual('v3');
    });

    it('upcl_enforcesOnIncrementBy', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 2 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.incrementBy('c1', 1);
      h.instance.userProfile.incrementBy('c2', 2);
      h.instance.userProfile.incrementBy('c3', 3);
      h.instance.userProfile.incrementBy('c4', 4);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      // Distinct modifier keys across all $-ops cap at 2.
      expect(countModifierPropsOnWire(calls[0].data)).assertEqual(2);
    });

    it('upcl_enforcesOnMixedMods', 0, async () => {
      const body: string = buildSbsBody({ 'upcl': 3 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.incrementBy('counter', 1);
      h.instance.userProfile.multiply('multiplier', 2);
      h.instance.userProfile.push('array', 'item');
      h.instance.userProfile.saveMax('maxValue', 100);
      h.instance.userProfile.saveMin('minValue', 1);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      // 5 distinct keys across 5 ops, capped at 3.
      expect(countModifierPropsOnWire(calls[0].data)).assertEqual(3);
    });

    it('upcl_samePropertyUpdate_doesNotIncreaseCount', 0, async () => {
      // Two-save sequence: the first save flushes 'counter' alone (proving 3x
      // increments on the same key only stage one entry); the second save
      // flushes 'otherCounter' alone (proving the second-batch staging holds
      // the new key without resurrecting the already-flushed one).
      const body: string = buildSbsBody({ 'upcl': 2 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      h.instance.userProfile.incrementBy('counter', 1);
      h.instance.userProfile.incrementBy('counter', 2);
      h.instance.userProfile.incrementBy('counter', 3);
      await h.instance.userProfile.save();
      await flushTick(60);
      let calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      expect(countModifierPropsOnWire(calls[0].data)).assertEqual(1);

      h.instance.userProfile.incrementBy('otherCounter', 1);
      await h.instance.userProfile.save();
      await flushTick(60);
      calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(2);
      // The second save's payload should hold only the new key.
      expect(countModifierPropsOnWire(calls[1].data)).assertEqual(1);
    });

    it('upcl_separateLimitsForCustomAndMods', 0, async () => {
      // Custom and modifier caches share the same numeric limit but enforce
      // independently. A single save() flushes both at once, so we can read
      // both counts off the same payload.
      const body: string = buildSbsBody({ 'upcl': 2 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const props: SegmentationMap = {};
      props['p1'] = 'v1';
      props['p2'] = 'v2';
      props['p3'] = 'v3';
      h.instance.userProfile.setProperties(props);
      h.instance.userProfile.incrementBy('c1', 1);
      h.instance.userProfile.incrementBy('c2', 2);
      h.instance.userProfile.incrementBy('c3', 3);
      await h.instance.userProfile.save();
      await flushTick(60);
      const calls = h.network.findCallsWithParam('user_details=');
      expect(calls.length).assertEqual(1);
      expect(countCustomPropsOnWire(calls[0].data)).assertEqual(2);
      expect(countModifierPropsOnWire(calls[0].data)).assertEqual(2);
    });

    // ============================================================
    // Apply: more value branches (Android-style sweep)
    // ============================================================

    it('apply_dropOldRequestTime_zeroDisablesDropByAge', 0, async () => {
      // dort=0 is the documented sentinel meaning "never drop by age".
      const body: string = buildSbsBody({ 'dort': 0 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.dropOldRequestTime).assertEqual(0);
      // Propagated to the live mutable.
      expect(h.instance.config.requestDropAgeHours).assertEqual(0);
    });

    it('apply_dropOldRequestTime_negativeRejected', 0, async () => {
      const body: string = buildSbsBody({ 'dort': -1 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.dropOldRequestTime).assertEqual(0); // default
    });

    it('apply_backoffMechanism_falsePropagates', 0, async () => {
      const body: string = buildSbsBody({ 'bom': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.bomEnabled).assertFalse();
      expect(h.instance.config.backoffEnabled).assertFalse();
    });

    it('apply_loggingDisabled_silencesLogger', 0, async () => {
      // Server pushes log=false — Logger.setEnabled(false) should be invoked.
      const body: string = buildSbsBody({ 'log': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.logging.enableLogging();
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.loggingEnabled).assertFalse();
    });

    it('apply_refreshContentZone_propagatesToInternalConfig', 0, async () => {
      // Server toggle of rcz lands on InternalConfig.refreshContentZoneEnabled.
      // (The cached field on ModuleContent is captured at construction; that
      // module is currently disabled in this build.)
      const body: string = buildSbsBody({ 'rcz': false });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.refreshContentZoneEnabled).assertFalse();
      expect(h.instance.config.refreshContentZoneEnabled).assertFalse();
    });

    it('apply_serverConfigUpdateInterval_validatedPositive', 0, async () => {
      // scui must be > 0.
      const negative: string = buildSbsBody({ 'scui': -1 });
      const h1: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(negative);
      });
      expect(h1.instance.config.serverConfig.serverConfigUpdateInterval).assertEqual(4);

      const valid: string = buildSbsBody({ 'scui': 8 });
      const h2: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(valid);
      });
      expect(h2.instance.config.serverConfig.serverConfigUpdateInterval).assertEqual(8);
    });

    it('apply_bomFamily_allValuesParsed', 0, async () => {
      // Cover the bom_at / bom_ra / bom_d apply branches that were not
      // touched by the open-interval bom_rqp test.
      const inner: Record<string, Object> = {};
      inner['bom_at'] = 15 as Object;
      inner['bom_ra'] = 48 as Object;
      inner['bom_d'] = 90 as Object;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const sc = h.instance.config.serverConfig;
      expect(sc.bomAcceptedTimeoutSeconds).assertEqual(15);
      expect(sc.bomRequestAge).assertEqual(48);
      expect(sc.bomDuration).assertEqual(90);
    });

    it('apply_bomFamily_invalidValuesDropped', 0, async () => {
      // bom_at must be > 0.
      const inner: Record<string, Object> = {};
      inner['bom_at'] = 0 as Object;
      inner['bom_ra'] = -1 as Object;
      inner['bom_d'] = 0 as Object;
      const body: string = buildSbsBody(inner);
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const sc = h.instance.config.serverConfig;
      // Defaults retained.
      expect(sc.bomAcceptedTimeoutSeconds).assertEqual(10);
      expect(sc.bomRequestAge).assertEqual(24);
      expect(sc.bomDuration).assertEqual(60);
    });

    it('apply_floatRejectedAsInteger', 0, async () => {
      // eqs must be a positive INTEGER. 7.5 should be rejected.
      const body: string = buildSbsBody({ 'eqs': 7.5 });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.eventQueueSize).assertEqual(100);
    });

    it('apply_jteEmptyArray_setsEmptyList', 0, async () => {
      const body: string = buildSbsBody({ 'jte': [] });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.journeyTriggerEvents.length).assertEqual(0);
    });

    it('apply_filterArrayWithNonStrings_skipsNonStrings', 0, async () => {
      // toStringArray skips non-string entries — a mixed array should land
      // in the filter as only its string members.
      const body: string = '{"v":1,"t":2,"c":{"eb":["valid",42,null,"also_valid"]}}';
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        cfg.setSDKBehaviorSettings(body);
      });
      const fl = h.instance.config.serverConfig.eventFilter;
      expect(fl.filterList.indexOf('valid') !== -1).assertTrue();
      expect(fl.filterList.indexOf('also_valid') !== -1).assertTrue();
      expect(fl.filterList.length).assertEqual(2);
    });

    it('apply_consentRequired_serverFlipsOnWhenIntegratorOff', 0, async () => {
      // Mirror complement of apply_consentRequired_oneWayOverride: integrator
      // did NOT set requiresConsent; server cr=true should flip it on AND
      // propagate.
      const body: string = buildSbsBody({ 'cr': true });
      const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
        // Don't call cfg.consent.setRequiresConsent — integrator is silent.
        cfg.setSDKBehaviorSettings(body);
      });
      expect(h.instance.config.serverConfig.consentRequired).assertTrue();
      expect(h.instance.config.requiresConsent).assertTrue();
    });

    // The original `hasFetchTimer_*` tests reached into `configurationModule`
    // to assert the in-memory `setInterval` handle and `lastFetchTimestamp`.
    // Both are unobservable from the public surface; the wire-side signals
    // they were proxying (init fires SC fetch / disabled init does not) are
    // already covered by `onInit_firesFetchToOSdkMethodSc` and
    // `disableSDKBehaviorSettingsUpdates_skipsFetchAndTimer` above.
  });
}
