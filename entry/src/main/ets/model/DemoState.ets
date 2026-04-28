import { CountlyFeedbackWidget, RCData, SegmentationMap, SegmentationValue } from 'countly-sdk-hos';

/**
 * AppStorage keys used across pages. Centralised so a typo in one page does
 * not silently create an orphaned AppStorage entry.
 */
export class StoreKeys {
  public static readonly LOG: string = 'demo_log';
  public static readonly LOG_EXPANDED: string = 'demo_log_expanded';
  public static readonly SDK_READY: string = 'demo_sdk_ready';
  public static readonly ACTIVE_VIEW_ID: string = 'demo_active_view_id';
  public static readonly ACTIVE_VIEW_NAME: string = 'demo_active_view_name';
  public static readonly ACTIVE_TRACE_KEY: string = 'demo_active_trace_key';
  public static readonly SECOND_INSTANCE_NAME: string = 'demo_second_instance_name';
  public static readonly SECOND_INSTANCE_CREATED: string = 'demo_second_instance_created';
  public static readonly CACHED_WIDGET_LABEL: string = 'demo_cached_widget_label';
}

/**
 * Singleton holder for objects that are too complex for AppStorage (typed
 * class instances, arrays of objects). Pages read these imperatively on tap;
 * reactive UI hints (a label showing the cached widget's name, etc.) live
 * in AppStorage under StoreKeys so @StorageLink rebinds every page.
 */
export class DemoState {
  public static cachedWidget: CountlyFeedbackWidget | null = null;
  public static availableWidgets: CountlyFeedbackWidget[] = [];
  public static lastRcValues: Record<string, RCData> = {};
}

/**
 * Ring-buffered log surface. UI binds via @StorageLink(StoreKeys.LOG) so every
 * page sees the same history after navigation.
 */
export class DemoLog {
  private static readonly CAP: number = 200;

  public static append(msg: string): void {
    const ts: string = new Date().toLocaleTimeString();
    const current: string[] = AppStorage.Get<string[]>(StoreKeys.LOG) ?? [];
    const next: string[] = [`${ts}  ${msg}`, ...current];
    AppStorage.SetOrCreate<string[]>(StoreKeys.LOG, next.slice(0, DemoLog.CAP));
  }

  public static clear(): void {
    AppStorage.SetOrCreate<string[]>(StoreKeys.LOG, []);
  }

  /**
   * Run `fn` (sync or async), auto-logging a tagged OK/ERR line. Any rejection
   * is caught so a fire-and-forget onClick handler does not produce an
   * unhandled promise warning.
   */
  public static async safe(tag: string, fn: () => Promise<void> | void): Promise<void> {
    try {
      const r: Promise<void> | void = fn();
      if (r instanceof Promise) await r;
      DemoLog.append(`${tag} OK`);
    } catch (e) {
      DemoLog.append(`${tag} ERR: ${e}`);
    }
  }
}

/**
 * "k=v,k2=v2" -> SegmentationMap. Values are parsed as numbers if they look
 * like numbers, booleans if they look like booleans, else strings. Empty
 * input yields an empty map, never null — the SDK treats missing segmentation
 * as null internally.
 */
export class SegParser {
  public static parse(raw: string): SegmentationMap {
    const out: SegmentationMap = {};
    if (!raw || raw.trim().length === 0) return out;
    const pairs: string[] = raw.split(',');
    for (let i = 0; i < pairs.length; i++) {
      const pair: string = pairs[i].trim();
      if (pair.length === 0) continue;
      const eq: number = pair.indexOf('=');
      if (eq === -1) continue;
      const key: string = pair.substring(0, eq).trim();
      const val: string = pair.substring(eq + 1).trim();
      if (key.length === 0) continue;
      out[key] = SegParser.coerce(val);
    }
    return out;
  }

  private static coerce(s: string): SegmentationValue {
    if (s === 'true') return true;
    if (s === 'false') return false;
    if (s.length > 0) {
      const n: number = Number(s);
      if (!isNaN(n) && isFinite(n)) return n;
    }
    return s;
  }
}
