import util from '@ohos.util';
import cryptoFramework from '@ohos.security.cryptoFramework';
import common from '@ohos.app.ability.common';
import Want from '@ohos.app.ability.Want';
import { Logger } from './Logger';
import { SegmentationMap, SegmentationValue } from '../types/Types';

/**
 * Shared helpers used across modules. Kept stateless where possible.
 */
export class Utils {
  private static lastMsTs: number = 0;

  /**
   * Returns a strictly monotonic millisecond timestamp. Two calls in the same
   * ms are split apart by bumping the last-used value, needed so the server
   * can order events/requests that arrive in the same batch.
   */
  public static uniqueTimestampMs(): number {
    let ts: number = Date.now();
    if (Utils.lastMsTs >= ts) {
      Utils.lastMsTs++;
    } else {
      Utils.lastMsTs = ts;
    }
    return Utils.lastMsTs;
  }

  public static hourOf(tsMs: number): number {
    return new Date(tsMs).getHours();
  }

  /**
   * URL-decode the value side of each `k=v` pair in a query-string body so
   * debug logs are human-readable. Keys are kept as-is (they're ASCII
   * identifiers); values get `decodeURIComponent`-ed individually so a
   * single malformed pair doesn't ruin the whole line. On decode failure
   * the original encoded value is preserved unchanged.
   */
  public static decodeQueryStringForLog(data: string): string {
    if (data.length === 0) return data;
    const parts: string[] = data.split('&');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const eq: number = parts[i].indexOf('=');
      if (eq === -1) { out.push(parts[i]); continue; }
      const k: string = parts[i].substring(0, eq);
      const v: string = parts[i].substring(eq + 1);
      let decoded: string = v;
      try { decoded = decodeURIComponent(v); } catch (e) { /* keep encoded */ }
      out.push(`${k}=${decoded}`);
    }
    return out.join('&');
  }

  /** 0 = Sunday ... 6 = Saturday (matches Countly server convention). */
  public static dayOfWeek(tsMs: number): number {
    return new Date(tsMs).getDay();
  }

  /** Timezone offset in minutes (positive for east of UTC). */
  public static timezoneOffsetMinutes(): number {
    return -new Date().getTimezoneOffset();
  }

  public static generateUUID(): string {
    return util.generateRandomUUID(true);
  }

  /**
   * Short event/view ID: random bytes base64-like encoded + ms timestamp.
   * Unique per call within the same process.
   */
  public static generateEventId(): string {
    const uuid: string = util.generateRandomUUID(false).replace(/-/g, '');
    return uuid.substring(0, 16) + Date.now().toString();
  }

  public static isNullOrEmpty(value: string | null | undefined): boolean {
    return value === null || value === undefined || value === '';
  }

  public static stripTrailingSlashes(url: string): string {
    let out: string = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  public static isValidUrl(url: string): boolean {
    if (Utils.isNullOrEmpty(url)) return false;
    return url.startsWith('http://') || url.startsWith('https://');
  }

  /**
   * Detailed server-URL validation. Returns a short reason code so callers
   * (CountlyConfig constructor, CountlyInstance.setServerURL) can map it to
   * their own throw / log-and-ignore behaviour.
   *
   * Codes:
   *   ''         , valid
   *   'empty'    , null / undefined / whitespace-only
   *   'scheme'   , missing http:// or https://
   *   'authority', contains userinfo (`@` before the path), e.g.
   *                 "https://legit.server.com@evil.com", RFC 3986 parses
   *                 the authority as `evil.com` so a misconfiguration here
   *                 silently redirects all telemetry.
   */
  public static validateServerUrl(url: string | null | undefined): string {
    if (url === null || url === undefined || url.trim().length === 0) return 'empty';
    if (!url.startsWith('http://') && !url.startsWith('https://')) return 'scheme';
    const schemeEnd: number = url.indexOf('://');
    const authorityEnd: number = url.indexOf('/', schemeEnd + 3);
    const authority: string = authorityEnd === -1
      ? url.substring(schemeEnd + 3)
      : url.substring(schemeEnd + 3, authorityEnd);
    if (authority.indexOf('@') !== -1) return 'authority';
    return '';
  }

  public static truncate(value: string, max: number): string {
    if (!value) return value;
    if (value.length <= max) return value;
    return value.substring(0, max);
  }

  /**
   * URL-encoded form body for POST: key=value&key=value with proper encoding.
   * Also used to build GET query strings.
   */
  public static buildQueryString(params: Record<string, string>): string {
    const parts: string[] = [];
    const keys: string[] = Object.keys(params);
    for (let i = 0; i < keys.length; i++) {
      const k: string = keys[i];
      const v: string = params[k];
      parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(v)}`);
    }
    return parts.join('&');
  }

  /**
   * SHA-256 hex digest. Uses HarmonyOS cryptoFramework. Async because the
   * framework exposes only an async API; callers queue requests while waiting.
   */
  public static async sha256Hex(input: string): Promise<string> {
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    const textEncoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = textEncoder.encodeInto(input);
    await md.update({ data: bytes });
    const digest: cryptoFramework.DataBlob = await md.digest();
    return Utils.bytesToHex(digest.data);
  }

  public static bytesToHex(bytes: Uint8Array): string {
    const hex: string[] = [];
    for (let i = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      hex.push((b < 16 ? '0' : '') + b.toString(16));
    }
    return hex.join('');
  }

  /**
   * Validates and sanitizes a segmentation map by dropping unsupported types
   * and enforcing key/value length limits. Returns a fresh copy.
   */
  public static sanitizeSegmentation(
    input: SegmentationMap | null | undefined,
    maxKeyLen: number,
    maxValueLen: number,
    maxEntries: number,
    onDrop?: (reason: string) => void
  ): SegmentationMap {
    const out: SegmentationMap = {};
    if (!input) return out;
    // First pass: filter/normalize every entry without applying the entry
    // cap. The cap trims oldest entries when over capacity, so the
    // surviving entries are the most recently inserted N.
    const filteredKeys: string[] = [];
    const filteredValues: SegmentationValue[] = [];
    const keys: string[] = Object.keys(input);
    for (let i = 0; i < keys.length; i++) {
      const rawKey: string = keys[i];
      if (Utils.isNullOrEmpty(rawKey)) {
        if (onDrop) onDrop('empty segmentation key');
        continue;
      }
      const value: SegmentationValue = input[rawKey];
      if (!Utils.isSupportedSegmentationValue(value)) {
        if (onDrop) onDrop(`unsupported segmentation value type for key '${rawKey}'`);
        continue;
      }
      const truncatedKey: string = Utils.truncate(rawKey, maxKeyLen);
      const truncatedValue: SegmentationValue = (typeof value === 'string')
        ? Utils.truncate(value, maxValueLen)
        : value;
      filteredKeys.push(truncatedKey);
      filteredValues.push(truncatedValue);
    }
    // Drop oldest until we're at the cap. After-cap-collision keys
    // (truncated to the same prefix) still collapse via the assignment
    // loop below.
    let startIdx: number = 0;
    while (filteredKeys.length - startIdx > maxEntries) {
      if (onDrop) onDrop(`segmentation entry count exceeded (${maxEntries})`);
      startIdx++;
    }
    for (let i = startIdx; i < filteredKeys.length; i++) {
      out[filteredKeys[i]] = filteredValues[i];
    }
    return out;
  }

  public static isSupportedSegmentationValue(v: SegmentationValue | undefined): boolean {
    if (v === null || v === undefined) return false;
    const t: string = typeof v;
    if (t === 'string' || t === 'number' || t === 'boolean') return true;
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i++) {
        const element: string | number | boolean = v[i];
        const et: string = typeof element;
        if (et !== 'string' && et !== 'number' && et !== 'boolean') return false;
      }
      return true;
    }
    return false;
  }

  /** Shallow merge, b overrides a. */
  public static mergeMaps(a: SegmentationMap, b: SegmentationMap): SegmentationMap {
    const out: SegmentationMap = {};
    const aKeys: string[] = Object.keys(a);
    for (let i = 0; i < aKeys.length; i++) out[aKeys[i]] = a[aKeys[i]];
    const bKeys: string[] = Object.keys(b);
    for (let i = 0; i < bKeys.length; i++) out[bKeys[i]] = b[bKeys[i]];
    return out;
  }

  /**
   * ArkTS bans Object.assign. These generic clone helpers produce a fresh Record
   * by copying each key explicitly, which is safe under arkts-limited-stdlib.
   */
  public static cloneStringRecord(src: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    const keys: string[] = Object.keys(src);
    for (let i = 0; i < keys.length; i++) out[keys[i]] = src[keys[i]];
    return out;
  }

  public static cloneSegmentationMap(src: SegmentationMap): SegmentationMap {
    const out: SegmentationMap = {};
    const keys: string[] = Object.keys(src);
    for (let i = 0; i < keys.length; i++) out[keys[i]] = src[keys[i]];
    return out;
  }

  /**
   * Escape regex metacharacters in a user-supplied literal so it can be
   * embedded in a `new RegExp(...)` pattern without accidental matches.
   */
  public static escapeForRegex(s: string): string {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /**
   * SDK-default external URL opener. Invoked from Content / Feedback when a
   * link action fires and no integrator-supplied opener is wired. Uses the
   * `UIAbilityContext` the integrator passed via `CountlyConfig(context,
   * ...)` to launch a view-data intent, the platform routes the URL to
   * the system browser or the registered default handler.
   *
   * Silent fail (with a warning log) is the right behavior here: external
   * links are optional UX, and a missing / wrong-typed context must not
   * crash the overlay.
   */
  public static openExternalUrlViaContext(ctx: common.Context | null, url: string, logger: Logger): void {
    if (ctx === null) {
      logger.w(`[Utils] openExternalUrl: no context available, dropped url=${url}`);
      return;
    }
    try {
      // `startAbility` lives on UIAbilityContext but not ApplicationContext.
      // Integrators who init from a UIAbility (the standard path) pass
      // UIAbilityContext; we cast and let the try/catch handle the edge
      // case where they passed something else.
      const uiCtx: common.UIAbilityContext = ctx as common.UIAbilityContext;
      const want: Want = { action: 'ohos.want.action.viewData', uri: url };
      uiCtx.startAbility(want).catch((err: Object): void => {
        logger.w(`[Utils] openExternalUrl, startAbility rejected: ${err}`);
      });
    } catch (err) {
      logger.w(`[Utils] openExternalUrl, context is not a UIAbilityContext: ${err}`);
    }
  }
}

export function escapeForRegex(s: string): string {
  return Utils.escapeForRegex(s);
}
