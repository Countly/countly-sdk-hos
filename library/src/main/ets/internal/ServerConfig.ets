import { Logger } from './Logger';
import { SegmentationMap } from '../types/Types';

/**
 * Whitelist/blacklist pair. `isWhitelist=true` means "keep only items IN the
 * list" and false means "drop items IN the list". Empty list means "allow
 * everything" regardless of the flag, that's the default state.
 *
 * Parametric over `T` so the payload can be a plain set of names (for
 * event/segmentation filters) OR a per-event map (for event-specific
 * segmentation filters).
 */
export class FilterList<T> {
  public filterList: T;
  public isWhitelist: boolean;
  constructor(filterList: T, isWhitelist: boolean) {
    this.filterList = filterList;
    this.isWhitelist = isWhitelist;
  }
}

/**
 * Runtime-tunable configuration the server pushes to the SDK via the
 * SDK-Behavior-Settings endpoint. Mirrors the dev guide §SDK Behavior
 * Settings table, every field has a sensible default that keeps the
 * SDK behaving identically when no settings are present.
 *
 * `ConfigurationProvider` (the public read interface in the dev guide)
 * is realised by direct field access on this class, modules read e.g.
 * `core.config.serverConfig.networkingEnabled` instead of going through a
 * named provider class. ArkTS strict mode rewards plain field reads (no
 * interface dispatch) and the surface is small enough that an extra
 * adapter would be ceremony rather than insulation.
 */
export class ServerConfig {
  // ---- Boolean feature flags (default true unless noted) ----
  /** `tracking`, master switch. False prevents new requests from being enqueued. */
  public trackingEnabled: boolean = true;
  /** `networking`, master switch. False keeps requests in the queue but blocks send. */
  public networkingEnabled: boolean = true;
  /** `st`, session tracking allowed. */
  public sessionTrackingEnabled: boolean = true;
  /** `vt`, view tracking allowed. */
  public viewTrackingEnabled: boolean = true;
  /** `cet`, custom event tracking allowed. Internal `[CLY]_*` events bypass. */
  public customEventTrackingEnabled: boolean = true;
  /** `crt`, crash reporting allowed. */
  public crashReportingEnabled: boolean = true;
  /** `lt`, location tracking allowed. */
  public locationTrackingEnabled: boolean = true;
  /** `ecz`, auto-enter content zone after init. Default false per dev guide. */
  public enterContentZoneEnabled: boolean = false;
  /** `rcz`, refresh content zone allowed. */
  public refreshContentZoneEnabled: boolean = true;
  /** `bom`, backoff mechanism enabled. */
  public bomEnabled: boolean = true;
  /** `log`, logging enabled. */
  public loggingEnabled: boolean = false;
  /** `cr`, consent required. */
  public consentRequired: boolean = false;

  // ---- Numeric settings (server-controllable knobs) ----
  /** `rqs`, request queue size. */
  public requestQueueSize: number = 1000;
  /** `eqs`, event queue size (batch threshold). */
  public eventQueueSize: number = 100;
  /** `sui`, session update interval seconds. */
  public sessionUpdateInterval: number = 60;
  /** `lkl`, key length limit (chars). */
  public limitKeyLength: number = 128;
  /** `lvs`, value size limit (chars). */
  public limitValueSize: number = 256;
  /** `lsv`, segmentation values count limit. */
  public limitSegmentationValues: number = 100;
  /** `lbc`, breadcrumb count limit. */
  public limitBreadcrumbCount: number = 100;
  /** `ltlpt`, stack trace lines per thread. */
  public limitStackTraceLineCount: number = 30;
  /** `ltl`, stack trace line length. */
  public limitStackTraceLineLength: number = 200;
  /** `czi`, content zone request interval seconds. Min 16. */
  public contentZoneInterval: number = 30;
  /** `scui`, server config update interval hours. */
  public serverConfigUpdateInterval: number = 4;
  /** `dort`, drop old request time hours. 0 disables drop-by-age. */
  public dropOldRequestTime: number = 0;
  /** `bom_at`, backoff accepted timeout seconds. */
  public bomAcceptedTimeoutSeconds: number = 10;
  /** `bom_rqp`, backoff request queue percentage (0..1 exclusive). */
  public bomRequestQueuePercentage: number = 0.5;
  /** `bom_ra`, backoff request age hours. */
  public bomRequestAge: number = 24;
  /** `bom_d`, backoff duration seconds. */
  public bomDuration: number = 60;
  /** `upcl`, user property cache limit. */
  public userPropertyCacheLimit: number = 100;

  // ---- Filters (mutable so the configuration module can update in place) ----
  public eventFilter: FilterList<string[]> = new FilterList<string[]>([], false);
  public segmentationFilter: FilterList<string[]> = new FilterList<string[]>([], false);
  public eventSegmentationFilter: FilterList<Record<string, string[]>> =
    new FilterList<Record<string, string[]>>({}, false);
  public userPropertyFilter: FilterList<string[]> = new FilterList<string[]>([], false);
  /** `jte`, event names that trigger a content-zone refresh. */
  public journeyTriggerEvents: string[] = [];
}

/**
 * Listing filter pipeline. Pure static helpers, no module state. The
 * filter semantics match the cross-SDK contract so the same server-side
 * filter config produces equivalent behaviour everywhere.
 */
export class ListingFilters {
  /**
   * Return true if the event name passes the event-name filter (empty list
   * always passes). Caller drops the event if this returns false.
   */
  public static applyEventFilter(eventName: string, sc: ServerConfig): boolean {
    return ListingFilters.applyListFilter(eventName, sc.eventFilter.filterList, sc.eventFilter.isWhitelist);
  }

  /**
   * Return true if a user-property key passes the filter. ModuleUserProfile
   * applies this on every set/setOnce/inc/push/pull/unset key.
   */
  public static applyUserPropertyFilter(propertyName: string, sc: ServerConfig): boolean {
    return ListingFilters.applyListFilter(propertyName, sc.userPropertyFilter.filterList, sc.userPropertyFilter.isWhitelist);
  }

  /**
   * Return a copy of `segmentation` with disallowed keys stripped. No-op
   * (returns the input reference) if the filter is empty. Returning a new
   * map mirrors `Utils.sanitizeSegmentation`, ArkTS strict mode rejects
   * the `delete` operator, so in-place mutation isn't available.
   */
  public static applySegmentationFilter(segmentation: SegmentationMap, sc: ServerConfig, logger: Logger): SegmentationMap {
    const fl: FilterList<string[]> = sc.segmentationFilter;
    if (fl.filterList.length === 0) return segmentation;
    return ListingFilters.filteredCopy(segmentation, fl.filterList, fl.isWhitelist, logger);
  }

  /**
   * Per-event segmentation filter. The config is a map of
   * `eventName → set<segKey>`; an event with no entry in the map keeps
   * all its segmentation.
   */
  public static applyEventSegmentationFilter(eventName: string, segmentation: SegmentationMap, sc: ServerConfig, logger: Logger): SegmentationMap {
    const fl: FilterList<Record<string, string[]>> = sc.eventSegmentationFilter;
    const keys: string[] = Object.keys(fl.filterList);
    if (keys.length === 0) return segmentation;
    const perEventList: string[] | undefined = fl.filterList[eventName];
    if (!perEventList || perEventList.length === 0) return segmentation;
    return ListingFilters.filteredCopy(segmentation, perEventList, fl.isWhitelist, logger);
  }

  private static applyListFilter(item: string, filterList: string[], isWhitelist: boolean): boolean {
    if (filterList.length === 0) return true;
    const contains: boolean = filterList.indexOf(item) !== -1;
    return isWhitelist === contains;
  }

  private static filteredCopy(map: SegmentationMap, filterList: string[], isWhitelist: boolean, logger: Logger): SegmentationMap {
    const out: SegmentationMap = {};
    const keys: string[] = Object.keys(map);
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      const contains: boolean = filterList.indexOf(key) !== -1;
      // Whitelist: keep if IN list. Blacklist: keep if NOT in list.
      const keep: boolean = isWhitelist ? contains : !contains;
      if (keep) {
        out[key] = map[key];
      } else {
        logger.d(`[ListingFilters] filteredCopy, removed key '${key}' (${isWhitelist ? 'not in whitelist' : 'blacklisted'})`);
      }
    }
    return out;
  }
}
