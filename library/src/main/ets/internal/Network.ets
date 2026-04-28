import http from '@ohos.net.http';
import { Logger } from './Logger';

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

  constructor(logger: Logger) {
    this.logger = logger;
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
        this.logger.w('[Network] setCustomHeaders, empty header name — dropped');
        continue;
      }
      if (denylist.indexOf(rawName.toLowerCase()) !== -1) {
        this.logger.w(`[Network] setCustomHeaders, '${rawName}' is reserved — dropped`);
        continue;
      }
      const value: string = headers[rawName];
      if (typeof value !== 'string') {
        this.logger.w(`[Network] setCustomHeaders, '${rawName}' value not a string — dropped`);
        continue;
      }
      if (rawName.indexOf('\r') !== -1 || rawName.indexOf('\n') !== -1 ||
          value.indexOf('\r') !== -1 || value.indexOf('\n') !== -1) {
        this.logger.e(`[Network] setCustomHeaders, '${rawName}' contains CR/LF — dropped (header-injection hazard)`);
        continue;
      }
      safe[rawName] = value;
    }
    this.customHeaders = safe;
  }

  public setForcePost(forced: boolean): void {
    this.forcePost = forced;
  }

  public async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
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
      const response: http.HttpResponse = await client.request(fullUrl, options);
      const body: string = typeof response.result === 'string'
        ? response.result
        : JSON.stringify(response.result);
      return {
        statusCode: response.responseCode,
        body: body,
        elapsedMs: Date.now() - start
      };
    } finally {
      client.destroy();
    }
  }

  public shouldUsePost(data: string): boolean {
    if (this.forcePost) return true;
    // Android/iOS threshold from the dev guide.
    return data.length > 2048;
  }
}
