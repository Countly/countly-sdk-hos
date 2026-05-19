import http from '@ohos.net.http';
import { Logger } from './Logger';
import { Utils } from './Utils';

export interface HttpResult {
  statusCode: number;
  body: string;
  elapsedMs: number;
}

/**
 * Thin wrapper over @ohos.net.http with support for custom headers, timeout,
 * and GET/POST switching. Each call creates its own HttpRequest so calls are
 * independently cancelable and don't share connection state.
 */
export class Network {
  protected logger: Logger;
  protected customHeaders: Record<string, string> = {};
  protected timeoutSec: number = 30;
  protected forcePost: boolean = false;
  /**
   * Global kill switch — when true, every `execute()` rejects immediately
   * with a `[Network] silenced` error and no HTTP request is made. Used
   * by Unknown Consent Mode to hold ALL server traffic locally while
   * the integrator's consent decision is pending. HC + SBS are gated
   * upstream by their owning modules (they check
   * `config.unknownConsentMode` and skip calling `execute()` entirely
   * during UCM); on UCM exit `resolveUnknownConsent` unsilences first
   * and fires HC + SBS explicitly. See brain note `ucm-hc-sbs-gate`
   * (countly-sdk-dart) for the cross-SDK design rationale.
   */
  protected silenced: boolean = false;

  constructor(logger: Logger) {
    this.logger = logger;
  }

  public setSilenced(silenced: boolean): void {
    this.silenced = silenced;
  }

  public setTimeoutSeconds(seconds: number): void {
    this.timeoutSec = Math.max(1, seconds);
  }

  /**
   * Accept only well-formed headers. CR/LF bytes allow header-splitting
   * attacks; a denylist of transport-owned headers prevents integrators from
   * accidentally smuggling a different Host or corrupting Content-Length.
   */
  public setCustomHeaders(headers: Record<string, string>): void {
    const safe: Record<string, string> = {};
    // Denylist covers: transport framing (host/content-length/te/transfer-
    // encoding/trailer/upgrade), SDK-owned headers (content-type/accept),
    // and headers integrators commonly inject from other code paths where a
    // leak would be especially damaging (cookie/authorization). "te" is
    // required for request smuggling attacks even if transfer-encoding is
    // already blocked.
    const denylist: string[] = [
      'host', 'content-length', 'transfer-encoding', 'te', 'trailer',
      'upgrade', 'connection', 'proxy-connection', 'expect',
      'content-type', 'accept',
      'cookie', 'authorization'
    ];
    const keys: string[] = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      const rawName: string = keys[i];
      if (!rawName || rawName.length === 0) {
        this.logger.w('[Network] setCustomHeaders, empty header name, dropped');
        continue;
      }
      if (denylist.indexOf(rawName.toLowerCase()) !== -1) {
        this.logger.w(`[Network] setCustomHeaders, '${rawName}' is reserved, dropped`);
        continue;
      }
      const value: string = headers[rawName];
      if (typeof value !== 'string') {
        this.logger.w(`[Network] setCustomHeaders, '${rawName}' value not a string, dropped`);
        continue;
      }
      if (rawName.indexOf('\r') !== -1 || rawName.indexOf('\n') !== -1 ||
          value.indexOf('\r') !== -1 || value.indexOf('\n') !== -1) {
        this.logger.e(`[Network] setCustomHeaders, '${rawName}' contains CR/LF, dropped (header-injection hazard)`);
        continue;
      }
      safe[rawName] = value;
    }
    this.customHeaders = safe;
  }

  public setForcePost(forced: boolean): void {
    this.forcePost = forced;
  }

  /**
   * Network request entry. Honors the UCM silencer (throws when
   * `silenced=true`). Used by every callsite, including HC + SBS;
   * those modules check `config.unknownConsentMode` themselves and
   * skip calling here when the SDK is in UCM. On UCM exit
   * `CountlyInstance.resolveUnknownConsent` unsilences first and then
   * fires HC + SBS explicitly, matching Dart's "block-then-fire-on-
   * exit" model (see brain note `ucm-hc-sbs-gate` for the design
   * rationale).
   */
  public async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    if (this.silenced) {
      // No HTTP issued. Throw is consistent with the underlying http
      // stack (which throws on transport errors); every caller already
      // wraps execute() in try/catch for that path, so the silencer
      // reuses the same exit. INFO log here so the silencer's effect is
      // visible during UCM investigations without grepping each
      // caller's catch block.
      this.logger.i(`[Network] REQUEST BLOCKED (silenced) endpoint=${endpoint} bytes=${data.length}`);
      throw new Error('[Network] silenced, request blocked');
    }
    return await this.executeRaw(baseUrl, endpoint, data, usePost);
  }

  /**
   * Inner HTTP runner. The silencer check lives in `execute()`; this
   * method is purely the transport. Kept as a separate method so future
   * additions (retry wrappers, alt paths) can share it without
   * re-implementing the request shape.
   */
  private async executeRaw(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    // INFO log so direct-execute callsites (ModuleConfiguration SBS,
    // ModuleHealthCheck, ModuleRemoteConfig auto-download) are visible
    // alongside the RequestQueue REQUEST SENT logs. The matching SENT
    // log for queue-routed requests fires from RequestQueue.processHead
    // after the response lands; this entry is the "started" marker for
    // direct callers and the queue tick alike.
    this.logger.i(`[Network] REQUEST SENDING endpoint=${endpoint} usePost=${usePost} bytes=${data.length} data=${Utils.decodeQueryStringForLog(data)}`);
    const fullUrl: string = usePost
      ? `${baseUrl}${endpoint}`
      : `${baseUrl}${endpoint}?${data}`;

    const headers: Record<string, string> = {};
    const userKeys: string[] = Object.keys(this.customHeaders);
    for (let i = 0; i < userKeys.length; i++) {
      headers[userKeys[i]] = this.customHeaders[userKeys[i]];
    }
    if (usePost) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    headers['Accept'] = 'application/json';

    const options: http.HttpRequestOptions = {
      method: usePost ? http.RequestMethod.POST : http.RequestMethod.GET,
      header: headers,
      extraData: usePost ? data : undefined,
      connectTimeout: this.timeoutSec * 1000,
      readTimeout: this.timeoutSec * 1000,
      expectDataType: http.HttpDataType.STRING
    };

    const client: http.HttpRequest = http.createHttp();
    const start: number = Date.now();
    try {
      let response: http.HttpResponse;
      try {
        response = await client.request(fullUrl, options);
      } catch (err) {
        // Symmetry with the success branch, log the transport-level
        // failure too so direct-execute callsites (RC download, SBS,
        // HC) surface "we sent but got nothing back" in the same log
        // stream as their REQUEST SENDING entry. ArkTS strict mode
        // banned `throw err` directly (arkts-limited-throw), wrap in
        // Error so the caller's existing try/catch still handles it.
        const elapsed: number = Date.now() - start;
        // HMOS http errors are `BusinessError` objects with `code` +
        // `message` fields; the default `${err}` interpolation prints
        // `[object Object]`. Extract structured fields with a JSON
        // fallback so the log line tells you what actually broke.
        const errDesc: string = Network.describeError(err);
        this.logger.w(`[Network] REQUEST FAILED endpoint=${endpoint} elapsedMs=${elapsed} err=${errDesc}`);
        throw new Error(`[Network] request failed: ${errDesc}`);
      }
      const body: string = typeof response.result === 'string'
        ? response.result
        : JSON.stringify(response.result);
      const elapsed: number = Date.now() - start;
      // INFO log so direct-execute callsites (RC download, SBS, HC)
      // surface their response in the same log stream. Queue-routed
      // requests ALSO get logged here, plus a second REQUEST SENT log
      // in RequestQueue.processHead that adds queue context (remaining,
      // decoded data). Two entries per queued request is intentional,
      // they capture different phases (HTTP completion vs queue drop).
      // Full body intentionally (no truncation) for active debugging.
      this.logger.i(`[Network] REQUEST DONE endpoint=${endpoint} status=${response.responseCode} elapsedMs=${elapsed} data=${Utils.decodeQueryStringForLog(data)} response=${body}`);
      return {
        statusCode: response.responseCode,
        body: body,
        elapsedMs: elapsed
      };
    } finally {
      client.destroy();
    }
  }

  public shouldUsePost(data: string): boolean {
    if (this.forcePost) return true;
    // 2 KB threshold per the dev guide.
    return data.length > 2048;
  }

  /**
   * Pretty-print an unknown error for the failure log. HMOS HTTP
   * rejections are `BusinessError` instances with `code` + `message`;
   * the default `${err}` template interpolation prints `[object
   * Object]`, which is useless for debugging. Try structured fields
   * first, then `toString`, then JSON, then a fixed "unknown" sentinel.
   */
  private static describeError(err: Object): string {
    if (err === null || err === undefined) return 'unknown';
    const rec: Record<string, Object> = err as Record<string, Object>;
    const code: Object | undefined = rec['code'];
    const message: Object | undefined = rec['message'];
    if (message !== undefined && code !== undefined) {
      return `code=${code} message=${message}`;
    }
    if (message !== undefined) return String(message);
    const toStringFn: Object | undefined = rec['toString'];
    if (typeof toStringFn === 'function') {
      const s: string = String(err);
      if (s !== '[object Object]') return s;
    }
    try {
      return JSON.stringify(err);
    } catch (jsonErr) {
      return 'unserializable error';
    }
  }
}
