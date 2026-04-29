import { ModuleBase } from '../ModuleBase';
import { SdkCore } from '../SdkCore';
import { InternalConfig } from '../InternalConfig';
import { ServerConfig, FilterList } from '../ServerConfig';
import { Utils } from '../Utils';

const STORAGE_KEY: string = 'cly_sbs';

// Top-level keys in the server response
const K_VERSION: string = 'v';
const K_TIMESTAMP: string = 't';
const K_CONFIG: string = 'c';

// Inner-config keys (`c.<key>`) — names match the dev guide table verbatim
const K_TRACKING: string = 'tracking';
const K_NETWORKING: string = 'networking';
const K_SESSION_TRACKING: string = 'st';
const K_VIEW_TRACKING: string = 'vt';
const K_CUSTOM_EVENT_TRACKING: string = 'cet';
const K_CRASH_REPORTING: string = 'crt';
const K_LOCATION_TRACKING: string = 'lt';
const K_ENTER_CONTENT_ZONE: string = 'ecz';
const K_REFRESH_CONTENT_ZONE: string = 'rcz';
const K_BACKOFF_MECHANISM: string = 'bom';
const K_LOGGING: string = 'log';
const K_CONSENT_REQUIRED: string = 'cr';

const K_REQUEST_QUEUE_SIZE: string = 'rqs';
const K_EVENT_QUEUE_SIZE: string = 'eqs';
const K_SESSION_UPDATE_INTERVAL: string = 'sui';
const K_LIMIT_KEY_LENGTH: string = 'lkl';
const K_LIMIT_VALUE_SIZE: string = 'lvs';
const K_LIMIT_SEG_VALUES: string = 'lsv';
const K_LIMIT_BREADCRUMB: string = 'lbc';
const K_LIMIT_TRACE_LINE: string = 'ltlpt';
const K_LIMIT_TRACE_LENGTH: string = 'ltl';
const K_CONTENT_ZONE_INTERVAL: string = 'czi';
const K_SERVER_CONFIG_UPDATE_INTERVAL: string = 'scui';
const K_DROP_OLD_REQUEST_TIME: string = 'dort';
const K_BOM_ACCEPTED_TIMEOUT: string = 'bom_at';
const K_BOM_RQ_PERCENTAGE: string = 'bom_rqp';
const K_BOM_REQUEST_AGE: string = 'bom_ra';
const K_BOM_DURATION: string = 'bom_d';
const K_USER_PROPERTY_CACHE_LIMIT: string = 'upcl';

const K_EVENT_BLACKLIST: string = 'eb';
const K_EVENT_WHITELIST: string = 'ew';
const K_USER_PROP_BLACKLIST: string = 'upb';
const K_USER_PROP_WHITELIST: string = 'upw';
const K_SEGMENTATION_BLACKLIST: string = 'sb';
const K_SEGMENTATION_WHITELIST: string = 'sw';
const K_EVENT_SEG_BLACKLIST: string = 'esb';
const K_EVENT_SEG_WHITELIST: string = 'esw';
const K_JOURNEY_TRIGGER_EVENTS: string = 'jte';

const HOUR_IN_MS: number = 60 * 60 * 1000;

/**
 * SDK Behavior Settings module. Owns the round-trip with `/o/sdk?method=sc`:
 * loads persisted/dev-supplied bootstrap config, validates the inner `c`
 * object against the dev-guide schema, applies surviving keys to the
 * `ServerConfig` field on `InternalConfig` (and propagates a few values to
 * other live mutables — `Limits`, `eventQueueThreshold`, `maxRequestQueueSize`,
 * `sessionUpdateIntervalSec`, `requestDropAgeHours`, `backoffEnabled`,
 * `requiresConsent`, content-zone interval / refresh).
 *
 * Lifecycle ordering matters: this module's *constructor* applies any
 * already-persisted settings (so the rest of `CountlyInstance` constructs
 * against the post-applied values). The fetch happens in `onInit`, after
 * the device-id resolves — temporary mode skips fetch entirely per dev guide.
 *
 * Differences from Android (kept tight on purpose):
 *   - HOS: storage key is `cly_sbs` (matches the comment in `Storage.ets`).
 *   - HOS: applies values directly to `InternalConfig` + `Limits` instead of
 *     mutating the user-facing `CountlyConfig` (which is consumed once at
 *     construction). End shape on the wire is the same.
 */
export class ModuleConfiguration extends ModuleBase {
  private core: SdkCore;
  // null = no timer scheduled (see ModuleConsent.pendingCoalesceTimer for the
  // sentinel-collision rationale: HMOS's setInterval may legitimately return 0).
  private fetchTimer: number | null = null;
  private latestRetrievedFull: Record<string, Object> | null = null;
  private latestRetrievedInner: Record<string, Object> | null = null;

  constructor(config: InternalConfig, core: SdkCore) {
    super(config);
    this.config.logger.v('[ModuleConfiguration] Initialising');
    this.core = core;
  }

  // -- Lifecycle --

  /**
   * Synchronous apply of the dev-supplied SBS only. Called by
   * `CountlyInstance` BEFORE other module constructors run so consent /
   * limits / queue thresholds reflect the dev-supplied baseline at the
   * time those modules cache them. Storage IO is async and happens later
   * via `loadFromStorage()`; the stored blob then takes precedence per
   * the dev guide.
   */
  public applyDevSuppliedSettings(): void {
    if (this.config.sdkBehaviorSettings) {
      this.applyRawSettings(this.config.sdkBehaviorSettings, 'dev-supplied (sync)');
    }
  }

  /**
   * Two-phase apply. Phase 1 (storage prelude) must be called BEFORE other
   * modules read the live mutables — invoked by `CountlyInstance` right
   * after `Storage.init()`. Phase 2 (server fetch) happens in `onInit`
   * after device-id resolves.
   */
  public async loadFromStorage(): Promise<void> {
    if (!this.config.storage) {
      // No storage — fall back to dev-supplied bootstrap if any.
      if (this.config.sdkBehaviorSettings) {
        this.applyRawSettings(this.config.sdkBehaviorSettings, 'dev-supplied');
      }
      return;
    }
    const stored: string = await this.config.storage.getString(STORAGE_KEY, '');
    if (stored.length > 0) {
      // Stored wins over dev-supplied per dev guide precedence table.
      this.applyRawSettings(stored, 'stored');
      return;
    }
    if (this.config.sdkBehaviorSettings) {
      this.applyRawSettings(this.config.sdkBehaviorSettings, 'dev-supplied');
      // Persist the bootstrap so subsequent restarts treat it as stored.
      await this.config.storage.setString(STORAGE_KEY, this.config.sdkBehaviorSettings);
    }
  }

  public override async onInit(): Promise<void> {
    if (this.config.sdkBehaviorSettingsRequestsDisabled) {
      this.config.logger.d('[ModuleConfiguration] onInit, SBS updates disabled by config — skipping fetch + timer');
      return;
    }
    if (this.core.deviceIdModule.isTemporary()) {
      this.config.logger.d('[ModuleConfiguration] onInit, temporary device id — skipping fetch (dev guide §SDK Behavior Settings)');
      return;
    }
    await this.fetchFromServer();
    this.startFetchTimer();
  }

  public override async onHalt(): Promise<void> {
    this.stopFetchTimer();
  }

  public override async onDeviceIdChangedNotMerged(oldId: string, newId: string): Promise<void> {
    // After a device-id swap (user switch), refresh once — settings can be
    // user-segment-targeted on the server. Skip if temp / disabled.
    if (this.config.sdkBehaviorSettingsRequestsDisabled) return;
    if (this.core.deviceIdModule.isTemporary()) return;
    await this.fetchFromServer();
  }

  // -- Fetch + persistence --

  private async fetchFromServer(): Promise<void> {
    const base: Record<string, string> = this.core.requestBuilder.baseParams();
    base['method'] = 'sc';
    const qs: string = Utils.buildQueryString(base);
    this.config.logger.d('[ModuleConfiguration] fetchFromServer, sending /o/sdk?method=sc');

    try {
      const res = await this.config.network.execute(this.config.serverUrl, '/o/sdk', qs, true);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        this.config.logger.w(`[ModuleConfiguration] fetchFromServer, http ${res.statusCode} — keeping existing settings`);
        return;
      }
      this.applyRawSettings(res.body, 'server');
      // Persist the merged result so the next launch starts from current state.
      if (this.config.storage && this.latestRetrievedFull !== null) {
        await this.config.storage.setString(STORAGE_KEY, JSON.stringify(this.latestRetrievedFull));
      }
    } catch (err) {
      this.config.logger.w(`[ModuleConfiguration] fetchFromServer, network error — keeping existing settings: ${err}`);
    }
  }

  private startFetchTimer(): void {
    this.stopFetchTimer();
    const intervalMs: number = this.config.serverConfig.serverConfigUpdateInterval * HOUR_IN_MS;
    if (!Number.isFinite(intervalMs) || intervalMs <= 0) return;
    this.fetchTimer = setInterval(() => {
      // Re-check temp / disabled at fire-time — state may have flipped since timer start.
      if (this.config.sdkBehaviorSettingsRequestsDisabled) return;
      if (this.core.deviceIdModule.isTemporary()) return;
      this.fetchFromServer().catch((err: Object) => {
        this.config.logger.e(`[ModuleConfiguration] periodic fetch rejected: ${err}`);
      });
    }, intervalMs) as number;
  }

  private stopFetchTimer(): void {
    if (this.fetchTimer !== null) {
      clearInterval(this.fetchTimer);
      this.fetchTimer = null;
    }
  }

  // -- Validation + apply --

  private applyRawSettings(raw: string, origin: string): void {
    let parsed: Object;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      this.config.logger.w(`[ModuleConfiguration] applyRawSettings (${origin}), JSON parse failed — ignoring: ${err}`);
      return;
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      this.config.logger.w(`[ModuleConfiguration] applyRawSettings (${origin}), root is not a JSON object — ignoring`);
      return;
    }
    const full: Record<string, Object> = parsed as Record<string, Object>;
    if (!this.validateEnvelope(full, origin)) return;

    const inner: Record<string, Object> = full[K_CONFIG] as Record<string, Object>;
    // Drop unknown / type-invalid keys before merging so future server keys
    // don't poison the persisted blob.
    const cleaned: Record<string, Object> = this.removeUnsupportedKeys(inner);
    if (Object.keys(cleaned).length === 0) {
      this.config.logger.d(`[ModuleConfiguration] applyRawSettings (${origin}), inner config empty after validation — nothing to apply`);
      return;
    }

    // Merge: server response is authoritative for keys it includes; preserve
    // others (so partial server response doesn't reset everything).
    if (this.latestRetrievedFull === null) {
      this.latestRetrievedFull = {};
      this.latestRetrievedInner = {};
      this.latestRetrievedFull[K_CONFIG] = this.latestRetrievedInner;
    }
    this.latestRetrievedFull[K_TIMESTAMP] = full[K_TIMESTAMP];
    this.latestRetrievedFull[K_VERSION] = full[K_VERSION];

    // Filter-key opposition: a non-empty whitelist for a category clears any
    // previously-stored blacklist for that category, and vice-versa. Mirrors
    // Android's `removeListingFilterKeysFromConfig`.
    this.purgeOppositeFilterKeys(cleaned);
    const innerKeys: string[] = Object.keys(cleaned);
    for (let i = 0; i < innerKeys.length; i++) {
      const k: string = innerKeys[i];
      this.latestRetrievedInner![k] = cleaned[k];
    }

    this.applyToServerConfig(this.latestRetrievedInner!);
    this.config.logger.i(`[ModuleConfiguration] applyRawSettings (${origin}), applied ${innerKeys.length} key(s)`);
  }

  private validateEnvelope(full: Record<string, Object>, origin: string): boolean {
    if (full[K_VERSION] === undefined) {
      this.config.logger.w(`[ModuleConfiguration] validate (${origin}), missing 'v' field — ignoring`);
      return false;
    }
    if (full[K_TIMESTAMP] === undefined) {
      this.config.logger.w(`[ModuleConfiguration] validate (${origin}), missing 't' field — ignoring`);
      return false;
    }
    const c: Object | undefined = full[K_CONFIG];
    if (c === undefined || c === null || typeof c !== 'object' || Array.isArray(c)) {
      this.config.logger.w(`[ModuleConfiguration] validate (${origin}), missing or invalid 'c' object — ignoring`);
      return false;
    }
    return true;
  }

  /**
   * Filter inner-config keys to those the SDK knows about AND whose value
   * type matches the expected schema. Returns a new object — does not mutate
   * the input. Mirrors Android's `removeUnsupportedKeys` switch.
   */
  private removeUnsupportedKeys(inner: Record<string, Object>): Record<string, Object> {
    const out: Record<string, Object> = {};
    const keys: string[] = Object.keys(inner);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const v: Object = inner[k];
      if (this.isValidKeyValue(k, v)) {
        out[k] = v;
      } else {
        this.config.logger.w(`[ModuleConfiguration] removeUnsupportedKeys, dropped '${k}' (invalid or unknown)`);
      }
    }
    return out;
  }

  private isIntegerAtLeast(value: Object, lowerBound: number): boolean {
    if (typeof value !== 'number') return false;
    const n: number = value as number;
    return Number.isFinite(n) && n >= lowerBound && Math.floor(n) === n;
  }

  private isValidKeyValue(key: string, value: Object): boolean {
    // Booleans
    if (key === K_TRACKING || key === K_NETWORKING || key === K_SESSION_TRACKING ||
        key === K_VIEW_TRACKING || key === K_CUSTOM_EVENT_TRACKING || key === K_CRASH_REPORTING ||
        key === K_LOCATION_TRACKING || key === K_ENTER_CONTENT_ZONE || key === K_REFRESH_CONTENT_ZONE ||
        key === K_BACKOFF_MECHANISM || key === K_LOGGING || key === K_CONSENT_REQUIRED) {
      return typeof value === 'boolean';
    }
    // Positive integers (>= 1)
    if (key === K_REQUEST_QUEUE_SIZE || key === K_EVENT_QUEUE_SIZE || key === K_SESSION_UPDATE_INTERVAL ||
        key === K_LIMIT_KEY_LENGTH || key === K_LIMIT_VALUE_SIZE || key === K_LIMIT_SEG_VALUES ||
        key === K_LIMIT_BREADCRUMB || key === K_LIMIT_TRACE_LINE || key === K_LIMIT_TRACE_LENGTH ||
        key === K_SERVER_CONFIG_UPDATE_INTERVAL || key === K_BOM_ACCEPTED_TIMEOUT ||
        key === K_BOM_REQUEST_AGE || key === K_BOM_DURATION || key === K_USER_PROPERTY_CACHE_LIMIT) {
      return this.isIntegerAtLeast(value, 1);
    }
    // Non-negative integer (>= 0)
    if (key === K_DROP_OLD_REQUEST_TIME) {
      return this.isIntegerAtLeast(value, 0);
    }
    // Min-16 integer
    if (key === K_CONTENT_ZONE_INTERVAL) {
      return this.isIntegerAtLeast(value, 16);
    }
    // Open (0,1) double
    if (key === K_BOM_RQ_PERCENTAGE) {
      return typeof value === 'number' && Number.isFinite(value as number) && (value as number) > 0 && (value as number) < 1;
    }
    // Filter list arrays of strings
    if (key === K_EVENT_BLACKLIST || key === K_EVENT_WHITELIST ||
        key === K_USER_PROP_BLACKLIST || key === K_USER_PROP_WHITELIST ||
        key === K_SEGMENTATION_BLACKLIST || key === K_SEGMENTATION_WHITELIST ||
        key === K_JOURNEY_TRIGGER_EVENTS) {
      return Array.isArray(value);
    }
    // Per-event segmentation filter object
    if (key === K_EVENT_SEG_BLACKLIST || key === K_EVENT_SEG_WHITELIST) {
      return value !== null && typeof value === 'object' && !Array.isArray(value);
    }
    return false;
  }

  private purgeOppositeFilterKeys(newCleaned: Record<string, Object>): void {
    if (this.latestRetrievedInner === null) return;
    const hasWhitelist: boolean =
      newCleaned[K_EVENT_WHITELIST] !== undefined ||
      newCleaned[K_USER_PROP_WHITELIST] !== undefined ||
      newCleaned[K_SEGMENTATION_WHITELIST] !== undefined ||
      newCleaned[K_EVENT_SEG_WHITELIST] !== undefined;
    const hasBlacklist: boolean =
      newCleaned[K_EVENT_BLACKLIST] !== undefined ||
      newCleaned[K_USER_PROP_BLACKLIST] !== undefined ||
      newCleaned[K_SEGMENTATION_BLACKLIST] !== undefined ||
      newCleaned[K_EVENT_SEG_BLACKLIST] !== undefined;

    // ArkTS strict mode bans the `delete` operator (arkts-no-delete-operator).
    // Rebuild the inner record without the opposite keys instead.
    const dropKeys: string[] = [];
    if (hasWhitelist) {
      dropKeys.push(K_EVENT_BLACKLIST);
      dropKeys.push(K_USER_PROP_BLACKLIST);
      dropKeys.push(K_SEGMENTATION_BLACKLIST);
      dropKeys.push(K_EVENT_SEG_BLACKLIST);
    }
    if (hasBlacklist) {
      dropKeys.push(K_EVENT_WHITELIST);
      dropKeys.push(K_USER_PROP_WHITELIST);
      dropKeys.push(K_SEGMENTATION_WHITELIST);
      dropKeys.push(K_EVENT_SEG_WHITELIST);
    }
    if (dropKeys.length === 0) return;

    const rebuilt: Record<string, Object> = {};
    const keys: string[] = Object.keys(this.latestRetrievedInner);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (dropKeys.indexOf(k) === -1) {
        rebuilt[k] = this.latestRetrievedInner[k];
      }
    }
    this.latestRetrievedInner = rebuilt;
    this.latestRetrievedFull![K_CONFIG] = rebuilt;
  }

  private applyToServerConfig(inner: Record<string, Object>): void {
    const sc: ServerConfig = this.config.serverConfig;

    // Booleans
    if (inner[K_TRACKING] !== undefined) sc.trackingEnabled = inner[K_TRACKING] as boolean;
    if (inner[K_NETWORKING] !== undefined) sc.networkingEnabled = inner[K_NETWORKING] as boolean;
    if (inner[K_SESSION_TRACKING] !== undefined) sc.sessionTrackingEnabled = inner[K_SESSION_TRACKING] as boolean;
    if (inner[K_VIEW_TRACKING] !== undefined) sc.viewTrackingEnabled = inner[K_VIEW_TRACKING] as boolean;
    if (inner[K_CUSTOM_EVENT_TRACKING] !== undefined) sc.customEventTrackingEnabled = inner[K_CUSTOM_EVENT_TRACKING] as boolean;
    if (inner[K_CRASH_REPORTING] !== undefined) sc.crashReportingEnabled = inner[K_CRASH_REPORTING] as boolean;
    if (inner[K_LOCATION_TRACKING] !== undefined) sc.locationTrackingEnabled = inner[K_LOCATION_TRACKING] as boolean;
    if (inner[K_ENTER_CONTENT_ZONE] !== undefined) sc.enterContentZoneEnabled = inner[K_ENTER_CONTENT_ZONE] as boolean;
    if (inner[K_REFRESH_CONTENT_ZONE] !== undefined) sc.refreshContentZoneEnabled = inner[K_REFRESH_CONTENT_ZONE] as boolean;
    if (inner[K_BACKOFF_MECHANISM] !== undefined) sc.bomEnabled = inner[K_BACKOFF_MECHANISM] as boolean;
    if (inner[K_LOGGING] !== undefined) {
      sc.loggingEnabled = inner[K_LOGGING] as boolean;
      this.config.logger.setEnabled(sc.loggingEnabled);
    }
    if (inner[K_CONSENT_REQUIRED] !== undefined) sc.consentRequired = inner[K_CONSENT_REQUIRED] as boolean;

    // Numbers
    if (inner[K_REQUEST_QUEUE_SIZE] !== undefined) sc.requestQueueSize = inner[K_REQUEST_QUEUE_SIZE] as number;
    if (inner[K_EVENT_QUEUE_SIZE] !== undefined) sc.eventQueueSize = inner[K_EVENT_QUEUE_SIZE] as number;
    if (inner[K_SESSION_UPDATE_INTERVAL] !== undefined) sc.sessionUpdateInterval = inner[K_SESSION_UPDATE_INTERVAL] as number;
    if (inner[K_LIMIT_KEY_LENGTH] !== undefined) sc.limitKeyLength = inner[K_LIMIT_KEY_LENGTH] as number;
    if (inner[K_LIMIT_VALUE_SIZE] !== undefined) sc.limitValueSize = inner[K_LIMIT_VALUE_SIZE] as number;
    if (inner[K_LIMIT_SEG_VALUES] !== undefined) sc.limitSegmentationValues = inner[K_LIMIT_SEG_VALUES] as number;
    if (inner[K_LIMIT_BREADCRUMB] !== undefined) sc.limitBreadcrumbCount = inner[K_LIMIT_BREADCRUMB] as number;
    if (inner[K_LIMIT_TRACE_LINE] !== undefined) sc.limitStackTraceLineCount = inner[K_LIMIT_TRACE_LINE] as number;
    if (inner[K_LIMIT_TRACE_LENGTH] !== undefined) sc.limitStackTraceLineLength = inner[K_LIMIT_TRACE_LENGTH] as number;
    if (inner[K_CONTENT_ZONE_INTERVAL] !== undefined) sc.contentZoneInterval = inner[K_CONTENT_ZONE_INTERVAL] as number;
    if (inner[K_SERVER_CONFIG_UPDATE_INTERVAL] !== undefined) sc.serverConfigUpdateInterval = inner[K_SERVER_CONFIG_UPDATE_INTERVAL] as number;
    if (inner[K_DROP_OLD_REQUEST_TIME] !== undefined) sc.dropOldRequestTime = inner[K_DROP_OLD_REQUEST_TIME] as number;
    if (inner[K_BOM_ACCEPTED_TIMEOUT] !== undefined) sc.bomAcceptedTimeoutSeconds = inner[K_BOM_ACCEPTED_TIMEOUT] as number;
    if (inner[K_BOM_RQ_PERCENTAGE] !== undefined) sc.bomRequestQueuePercentage = inner[K_BOM_RQ_PERCENTAGE] as number;
    if (inner[K_BOM_REQUEST_AGE] !== undefined) sc.bomRequestAge = inner[K_BOM_REQUEST_AGE] as number;
    if (inner[K_BOM_DURATION] !== undefined) sc.bomDuration = inner[K_BOM_DURATION] as number;
    if (inner[K_USER_PROPERTY_CACHE_LIMIT] !== undefined) sc.userPropertyCacheLimit = inner[K_USER_PROPERTY_CACHE_LIMIT] as number;

    // Filter lists. Whitelist beats blacklist (for the same category) per dev
    // guide §SDK Behavior Settings — we already purged opposite keys above.
    if (inner[K_EVENT_BLACKLIST] !== undefined) {
      sc.eventFilter = new FilterList<string[]>(this.toStringArray(inner[K_EVENT_BLACKLIST]), false);
    } else if (inner[K_EVENT_WHITELIST] !== undefined) {
      sc.eventFilter = new FilterList<string[]>(this.toStringArray(inner[K_EVENT_WHITELIST]), true);
    }
    if (inner[K_USER_PROP_BLACKLIST] !== undefined) {
      sc.userPropertyFilter = new FilterList<string[]>(this.toStringArray(inner[K_USER_PROP_BLACKLIST]), false);
    } else if (inner[K_USER_PROP_WHITELIST] !== undefined) {
      sc.userPropertyFilter = new FilterList<string[]>(this.toStringArray(inner[K_USER_PROP_WHITELIST]), true);
    }
    if (inner[K_SEGMENTATION_BLACKLIST] !== undefined) {
      sc.segmentationFilter = new FilterList<string[]>(this.toStringArray(inner[K_SEGMENTATION_BLACKLIST]), false);
    } else if (inner[K_SEGMENTATION_WHITELIST] !== undefined) {
      sc.segmentationFilter = new FilterList<string[]>(this.toStringArray(inner[K_SEGMENTATION_WHITELIST]), true);
    }
    if (inner[K_EVENT_SEG_BLACKLIST] !== undefined) {
      sc.eventSegmentationFilter = new FilterList<Record<string, string[]>>(
        this.toStringArrayMap(inner[K_EVENT_SEG_BLACKLIST]), false);
    } else if (inner[K_EVENT_SEG_WHITELIST] !== undefined) {
      sc.eventSegmentationFilter = new FilterList<Record<string, string[]>>(
        this.toStringArrayMap(inner[K_EVENT_SEG_WHITELIST]), true);
    }
    if (inner[K_JOURNEY_TRIGGER_EVENTS] !== undefined) {
      sc.journeyTriggerEvents = this.toStringArray(inner[K_JOURNEY_TRIGGER_EVENTS]);
    }

    // Propagate to live mutables ONLY for keys that arrived in this apply.
    // Skipping the propagation for absent keys preserves integrator-supplied
    // defaults (e.g. `requestDropAgeHours=168` from `NetworkConfig`) when the
    // server response doesn't override them. Mirrors Android's `extractValue`
    // contract: "no value present → keep existing".
    if (inner[K_LIMIT_KEY_LENGTH] !== undefined) this.config.limits.maxKeyLength = sc.limitKeyLength;
    if (inner[K_LIMIT_VALUE_SIZE] !== undefined) this.config.limits.maxValueSize = sc.limitValueSize;
    if (inner[K_LIMIT_SEG_VALUES] !== undefined) this.config.limits.maxSegmentationValues = sc.limitSegmentationValues;
    if (inner[K_LIMIT_BREADCRUMB] !== undefined) this.config.limits.maxBreadcrumbCount = sc.limitBreadcrumbCount;
    if (inner[K_LIMIT_TRACE_LINE] !== undefined) this.config.limits.maxStackTraceLinesPerThread = sc.limitStackTraceLineCount;
    if (inner[K_LIMIT_TRACE_LENGTH] !== undefined) this.config.limits.maxStackTraceLineLength = sc.limitStackTraceLineLength;

    if (inner[K_EVENT_QUEUE_SIZE] !== undefined) this.config.eventQueueThreshold = sc.eventQueueSize;
    if (inner[K_REQUEST_QUEUE_SIZE] !== undefined) this.config.maxRequestQueueSize = sc.requestQueueSize;
    if (inner[K_SESSION_UPDATE_INTERVAL] !== undefined) this.config.sessionUpdateIntervalSec = sc.sessionUpdateInterval;
    if (inner[K_DROP_OLD_REQUEST_TIME] !== undefined) this.config.requestDropAgeHours = sc.dropOldRequestTime;
    if (inner[K_BACKOFF_MECHANISM] !== undefined) this.config.backoffEnabled = sc.bomEnabled;
    // `consentRequired` from server is documented as a one-way override:
    // server says "you MUST require consent" — flip the integrator-set field
    // on, but never flip it OFF (an integrator who set requiresConsent=true
    // for a regulatory reason should not have it silently removed).
    // HOS: deliberately diverges from Android's bidirectional flip.
    if (inner[K_CONSENT_REQUIRED] !== undefined && sc.consentRequired) {
      this.config.requiresConsent = true;
    }
    if (inner[K_CONTENT_ZONE_INTERVAL] !== undefined) this.config.contentZoneInterval = sc.contentZoneInterval;
    if (inner[K_REFRESH_CONTENT_ZONE] !== undefined) this.config.refreshContentZoneEnabled = sc.refreshContentZoneEnabled;
  }

  private toStringArray(value: Object): string[] {
    if (!Array.isArray(value)) return [];
    const arr: Object[] = value as Object[];
    const out: string[] = [];
    for (let i = 0; i < arr.length; i++) {
      if (typeof arr[i] === 'string') out.push(arr[i] as string);
    }
    return out;
  }

  private toStringArrayMap(value: Object): Record<string, string[]> {
    const out: Record<string, string[]> = {};
    if (value === null || typeof value !== 'object' || Array.isArray(value)) return out;
    const obj: Record<string, Object> = value as Record<string, Object>;
    const keys: string[] = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      out[keys[i]] = this.toStringArray(obj[keys[i]]);
    }
    return out;
  }

}
