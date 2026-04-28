import { InternalConfig } from './InternalConfig';
import { Utils, escapeForRegex } from './Utils';
import { HttpResult, Network } from './Network';
import { Logger } from './Logger';
import { ServerConfig } from './ServerConfig';

export const TEMP_DEVICE_ID: string = 'CLYTemporaryDeviceID';
export const NEW_ENDPOINT_TAG: string = 'new_end_point';

/**
 * Endpoints the SDK is allowed to route to via the internal `new_end_point`
 * tag. Anything outside this set is silently rejected and the request is
 * routed to `/i` instead — defense against a disk-level attacker editing the
 * persisted queue to redirect traffic off the Countly server.
 */
const ALLOWED_ENDPOINTS: string[] = ['/i', '/o/sdk', '/o/sdk/content', '/feedback/widget'];

/**
 * Hard cap on the exponential backoff delay. The base of the exponential is
 * the server-tunable `bom_d` (`bomDuration` in seconds — default 60), so the
 * progression is `bom_d, 2·bom_d, 4·bom_d, …` capped here at 15 minutes
 * regardless of how aggressive the server tries to be.
 */
const BACKOFF_MAX_MS: number = 15 * 60 * 1000;

/**
 * Persistent FIFO request queue + the processor that drains it. One task loop
 * runs per instance; it's re-entrant-safe via a `processing` flag.
 *
 * Key behaviors enforced here:
 *   - drop-by-age (requestDropAgeHours)
 *   - 2048-char POST switchover
 *   - checksum256 append when salt is configured
 *   - temp-device-id suspension (don't send while in offline mode)
 *   - exponential-ish backoff on server stress signals
 */
/**
 * Hook interface for ModuleHealthCheck. Wired from CountlyInstance post-init.
 * Intentionally minimal — only the three counter-affecting signals are exposed
 * so this remains a pure diagnostic side-channel (no user-behavior data).
 */
export interface HealthListener {
  onFailedRequest(statusCode: number, body: string): void;
  onBackoff(): void;
  onSuccessfulSend(): void;
}

export class RequestQueue {
  private config: InternalConfig;
  private queue: string[] = [];
  private processing: boolean = false;
  private paused: boolean = false;
  private halted: boolean = false;
  private backoffUntilMs: number = 0;
  private backoffTimer: number = 0;
  private consecutiveBackedOff: number = 0;
  private processorTimer: number = 0;
  private tempMode: () => boolean;
  private healthListener: HealthListener | null = null;

  constructor(config: InternalConfig, tempMode: () => boolean) {
    this.config = config;
    this.tempMode = tempMode;
  }

  public setHealthListener(listener: HealthListener | null): void {
    this.healthListener = listener;
  }

  public async load(): Promise<void> {
    if (this.config.storage) {
      this.queue = await this.config.storage.loadRequestQueue();
    }
  }

  public size(): number {
    return this.queue.length;
  }

  public peekAll(): string[] {
    return this.queue.slice();
  }

  public pause(): void { this.paused = true; }
  public resume(): void {
    this.paused = false;
    this.scheduleTick();
  }
  public isPaused(): boolean { return this.paused; }

  /**
   * Drop every queued request without sending. Used by `flushQueues()` so both
   * the event queue and the request queue can be wiped in one shot. Started
   * timed events (ModuleEvents.timed) are NOT affected per dev guide.
   */
  public async clear(): Promise<void> {
    if (this.queue.length === 0) return;
    this.queue = [];
    await this.persist();
  }

  /**
   * Rewrite the `app_key=` parameter on every queued request to the current
   * app key. Use after an app-key change so previously-queued telemetry gets
   * associated with the new app instead of being discarded by the server.
   */
  public async replaceAllAppKeysWithCurrent(): Promise<void> {
    const encoded: string = encodeURIComponent(this.config.appKey);
    const rx: RegExp = /(^|&)app_key=[^&]*/g;
    let changed: boolean = false;
    for (let i = 0; i < this.queue.length; i++) {
      const next: string = this.queue[i].replace(rx, `$1app_key=${encoded}`);
      if (next !== this.queue[i]) { this.queue[i] = next; changed = true; }
    }
    if (changed) {
      await this.persist();
      this.scheduleTick();
    }
  }

  /**
   * Drop any queued request whose `app_key=` parameter differs from the
   * current app key. Paired with `replaceAllAppKeysWithCurrent` — use whichever
   * matches the integrator's "what should happen to old-app-key traffic?"
   * policy.
   */
  public async removeDifferentAppKeys(): Promise<void> {
    const encoded: string = encodeURIComponent(this.config.appKey);
    const before: number = this.queue.length;
    this.queue = this.queue.filter((r: string) => {
      const match: RegExpMatchArray | null = r.match(/(?:^|&)app_key=([^&]*)/);
      if (!match) return true;
      return match[1] === encoded;
    });
    if (this.queue.length !== before) {
      this.config.logger.d(`[RequestQueue] removeDifferentAppKeys, dropped ${before - this.queue.length} entries`);
      await this.persist();
    }
  }

  /**
   * Permanent stop: clear both scheduled ticks and backoff timers, refuse
   * future scheduleTick calls. Called from CountlyInstance.halt so timers
   * don't fire against a detached instance after shutdown.
   */
  public halt(): void {
    this.halted = true;
    this.paused = true;
    if (this.processorTimer !== 0) { clearTimeout(this.processorTimer); this.processorTimer = 0; }
    if (this.backoffTimer !== 0) { clearTimeout(this.backoffTimer); this.backoffTimer = 0; }
  }

  public async enqueue(requestData: string): Promise<void> {
    if (requestData.length === 0) return;
    // SDK Behavior Settings master tracking switch — server can short-circuit
    // all telemetry collection in flight. We drop here (not in feature
    // modules) so the kill is centralised and every code path is covered.
    if (!this.config.serverConfig.trackingEnabled) {
      this.config.logger.d('[RequestQueue] enqueue, tracking disabled by server config — dropped');
      return;
    }

    // Enforce max queue size by dropping oldest first.
    while (this.queue.length >= this.config.maxRequestQueueSize) {
      this.queue.shift();
      this.config.logger.w('[RequestQueue] enqueue, dropped oldest request (queue full)');
    }
    this.queue.push(requestData);
    // DEBUG — visible at default minLevel=DEBUG. Size is bounded so logging
    // it per enqueue is cheap; lets integrators trace the queue growth.
    this.config.logger.d(`[RequestQueue] enqueue, queued (size=${this.queue.length})`);
    await this.persist();
    this.scheduleTick();
  }

  /**
   * After temp-device-id mode ends, replace the placeholder `device_id=` value
   * in queued requests with the new real ID so they can be sent. Uses an
   * anchored regex so a user-set custom property value that happens to
   * contain the literal `CLYTemporaryDeviceID` is NOT rewritten — only the
   * query param itself is matched.
   */
  public async replaceTempDeviceId(realId: string): Promise<void> {
    const encodedPlaceholder: string = encodeURIComponent(TEMP_DEVICE_ID);
    const encodedReal: string = encodeURIComponent(realId);
    // Anchored: match `device_id=VALUE` only at start-of-string or after `&`,
    // and only up to the next `&` (or end). This is the param-position match
    // we actually want; plain `.replace` would also rewrite a field whose
    // VALUE contains the placeholder string.
    const rx: RegExp = new RegExp(`(^|&)device_id=${escapeForRegex(encodedPlaceholder)}(?=&|$)`, 'g');
    let changed: boolean = false;
    for (let i = 0; i < this.queue.length; i++) {
      const next: string = this.queue[i].replace(rx, `$1device_id=${encodedReal}`);
      if (next !== this.queue[i]) {
        this.queue[i] = next;
        changed = true;
      }
    }
    if (changed) {
      await this.persist();
      this.scheduleTick();
    }
  }

  /**
   * At init we may have orphaned temp-ID requests from a previous session. If
   * we're not in temp mode anymore and no real ID can claim them, drop them.
   * Uses the same anchored regex as replaceTempDeviceId so a request whose
   * user-property VALUE merely contains the placeholder string isn't falsely
   * orphaned.
   */
  public async cleanupOrphanedTempRequests(): Promise<void> {
    const encodedPlaceholder: string = encodeURIComponent(TEMP_DEVICE_ID);
    const rx: RegExp = new RegExp(`(^|&)device_id=${escapeForRegex(encodedPlaceholder)}(?=&|$)`);
    const before: number = this.queue.length;
    this.queue = this.queue.filter((r: string) => !rx.test(r));
    if (this.queue.length !== before) {
      this.config.logger.d(`[RequestQueue] cleanupOrphanedTempRequests, dropped ${before - this.queue.length} orphaned entries`);
      await this.persist();
    }
  }

  private scheduleTick(): void {
    if (this.halted) return;
    if (this.processorTimer !== 0) return;
    this.processorTimer = setTimeout(() => {
      this.processorTimer = 0;
      this.tick();
    }, 0) as number;
  }

  private async tick(): Promise<void> {
    if (this.halted) return;
    if (this.processing || this.paused) return;
    if (this.tempMode()) {
      this.config.logger.v('[RequestQueue] tick, temp device id mode active, not sending');
      return;
    }
    // SDK Behavior Settings networking switch — server can pause sending
    // without dropping queue contents. Requests stay durable; the next tick
    // after the server flips networking back on drains them.
    if (!this.config.serverConfig.networkingEnabled) {
      this.config.logger.v('[RequestQueue] tick, networking disabled by server config — holding queue');
      return;
    }
    if (Date.now() < this.backoffUntilMs) {
      // Schedule a single follow-up tick rather than stacking them. Without
      // this dedup, a flurry of enqueues during a backoff window each
      // triggers a scheduleTick → tick → setTimeout chain; they all fire at
      // once and all race on `processing`, producing wasteful contention.
      if (this.backoffTimer === 0) {
        const delay: number = this.backoffUntilMs - Date.now();
        this.backoffTimer = setTimeout(() => {
          this.backoffTimer = 0;
          this.scheduleTick();
        }, delay) as number;
      }
      return;
    }
    if (this.queue.length === 0) return;

    this.processing = true;
    try {
      await this.processHead();
    } finally {
      this.processing = false;
    }
    if (this.queue.length > 0) this.scheduleTick();
  }

  private async processHead(): Promise<void> {
    // Drop-by-age: check the head's "timestamp=" value.
    const head: string = this.queue[0];
    if (this.config.requestDropAgeHours > 0 && this.isTooOld(head)) {
      this.config.logger.w('[RequestQueue] processHead, dropping request by age');
      this.queue.shift();
      await this.persist();
      return;
    }

    // Strip the new_end_point tag (if any) so we route to the right endpoint.
    // The decoded endpoint MUST be in the allowlist — a disk-level attacker
    // who edits the persisted queue could otherwise redirect traffic.
    let endpoint: string = '/i';
    let requestData: string = head;
    const tagPrefix: string = `&${NEW_ENDPOINT_TAG}=`;
    const tagIdx: number = requestData.indexOf(tagPrefix);
    if (tagIdx !== -1) {
      const after: number = tagIdx + tagPrefix.length;
      let end: number = requestData.indexOf('&', after);
      if (end === -1) end = requestData.length;
      const raw: string = requestData.substring(after, end);
      let requested: string = '';
      try {
        requested = decodeURIComponent(raw);
      } catch (decodeErr) {
        // A disk-level attacker could craft a malformed %XX in the persisted
        // queue to make decodeURIComponent throw. Rather than letting the
        // whole tick fail into backoff, treat this as an unknown endpoint
        // and route to the default /i.
        this.config.logger.w(`[RequestQueue] processHead, malformed new_end_point value '${raw}' — falling back to /i`);
      }
      if (ALLOWED_ENDPOINTS.indexOf(requested) !== -1) {
        endpoint = requested;
      } else if (requested.length > 0) {
        this.config.logger.w(`[RequestQueue] processHead, rejected endpoint override '${requested}' — falling back to /i`);
      }
      requestData = requestData.substring(0, tagIdx) + requestData.substring(end);
    }

    // Append rr (remaining) just before sending.
    const remaining: number = this.queue.length - 1;
    requestData += `&rr=${remaining}`;

    // Apply tampering salt if configured.
    if (this.config.parameterTamperingSalt) {
      const hash: string = await Utils.sha256Hex(requestData + this.config.parameterTamperingSalt);
      requestData += `&checksum256=${hash}`;
    }

    const network: Network = this.config.network;
    const usePost: boolean = network.shouldUsePost(requestData);
    let result: HttpResult | null = null;
    try {
      result = await network.execute(this.config.serverUrl, endpoint, requestData, usePost);
    } catch (err) {
      // Log at WARNING so this isn't invisible on default levels; include
      // endpoint + redacted preview so integrators can diagnose without
      // spilling device_id / app_key into cloud log sinks.
      this.config.logger.w(
        `[RequestQueue] processHead, network error endpoint=${endpoint} err=${err} data=${RequestQueue.redactPreview(requestData)}`
      );
      if (this.healthListener !== null) this.healthListener.onFailedRequest(-1, String(err));
      this.enterBackoff();
      return;
    }

    const decision: string = RequestQueue.classify(this.config.logger, result);
    if (decision === 'drop') {
      this.config.logger.e(`[RequestQueue] processHead, dropping head after unrecoverable response status=${result.statusCode} endpoint=${endpoint}`);
      if (this.healthListener !== null) this.healthListener.onFailedRequest(result.statusCode, result.body);
      this.queue.shift();
      this.consecutiveBackedOff = 0;
      await this.persist();
      return;
    }
    if (decision === 'retry') {
      this.config.logger.w(`[RequestQueue] processHead, retrying after transient failure status=${result.statusCode} endpoint=${endpoint}`);
      if (this.healthListener !== null) this.healthListener.onFailedRequest(result.statusCode, result.body);
      this.enterBackoff();
      return;
    }

    // Success — reset backoff and remove head.
    this.queue.shift();
    this.consecutiveBackedOff = 0;
    await this.persist();
    this.config.logger.d(`[RequestQueue] processHead, sent OK endpoint=${endpoint} elapsedMs=${result.elapsedMs} remaining=${this.queue.length}`);
    if (this.healthListener !== null) this.healthListener.onSuccessfulSend();

    if (this.config.backoffEnabled) {
      this.evaluateBackoff(result, requestData);
    }
  }

  /**
   * Enter backoff with exponential delay: bom_d, 2·bom_d, 4·bom_d, ... capped
   * at 15 minutes. On the first success, `consecutiveBackedOff` resets so the
   * next failure starts back at bom_d. The base is server-tunable via
   * `bom_d` (default 60s); the multiplier and ceiling are not.
   */
  private enterBackoff(): void {
    const baseMs: number = this.config.serverConfig.bomDuration * 1000;
    const exponent: number = Math.min(this.consecutiveBackedOff, 8);
    const delay: number = Math.min(baseMs * Math.pow(2, exponent), BACKOFF_MAX_MS);
    this.backoffUntilMs = Date.now() + delay;
    this.consecutiveBackedOff++;
    if (this.healthListener !== null) this.healthListener.onBackoff();
    this.config.logger.i(`[RequestQueue] enterBackoff, delay=${delay / 1000}s consecutive=${this.consecutiveBackedOff}`);
  }

  /**
   * Slow-success backoff (BOM in dev guide §SDK Behavior Settings). Triggered
   * when a request succeeds but the server is straining — three gates must
   * all pass:
   *   - response time ≥ `bom_at` seconds (server is slow)
   *   - queue ≤ `bom_rqp` of capacity (we can afford to pause)
   *   - request not older than `bom_ra` hours (slow response is "current",
   *     not just a stale request finally getting through)
   * On trigger, pause for `bom_d` seconds. Mirrors Android's
   * `ConnectionProcessor.backoff(...)` decision tree.
   */
  private evaluateBackoff(result: HttpResult, requestData: string): void {
    const sc: ServerConfig = this.config.serverConfig;
    const acceptedTimeoutMs: number = sc.bomAcceptedTimeoutSeconds * 1000;
    if (result.elapsedMs < acceptedTimeoutMs) return;
    const threshold: number = sc.bomRequestQueuePercentage;
    const queueRatio: number = this.queue.length / this.config.maxRequestQueueSize;
    if (queueRatio > threshold) return;
    if (this.isOlderThanHours(requestData, sc.bomRequestAge)) {
      this.config.logger.d('[RequestQueue] evaluateBackoff, head request older than bom_ra — skip');
      return;
    }
    const pauseMs: number = sc.bomDuration * 1000;
    this.backoffUntilMs = Date.now() + pauseMs;
    if (this.healthListener !== null) this.healthListener.onBackoff();
    this.config.logger.d(`[RequestQueue] evaluateBackoff, slow server — pausing ${sc.bomDuration}s`);
  }

  /** Used by both `dropOldRequestTime` (drop-by-age) and `bom_ra` (skip
   *  backoff for stale heads). Unparseable timestamps are treated as stale
   *  so corrupt persisted entries don't pin the queue forever. */
  private isOlderThanHours(requestData: string, hours: number): boolean {
    const match: RegExpMatchArray | null = requestData.match(/(?:^|&)timestamp=(\d+)/);
    if (!match) return false;
    const tsMs: number = parseInt(match[1], 10);
    if (!Number.isFinite(tsMs)) {
      this.config.logger.w('[RequestQueue] isOlderThanHours, unparseable timestamp — treating as stale');
      return true;
    }
    const ageMs: number = Date.now() - tsMs;
    return ageMs >= hours * 3600 * 1000;
  }

  private isTooOld(requestData: string): boolean {
    return this.isOlderThanHours(requestData, this.config.requestDropAgeHours);
  }

  /**
   * Decide what to do with a completed HTTP response:
   *   'success' — 2xx with valid JSON containing "result"; shift head, reset backoff
   *   'drop'    — 4xx (permanent), or 2xx without "result" (broken proxy);
   *               shift head with ERROR log, reset backoff. Retrying forever
   *               wastes battery/data.
   *   'retry'   — 5xx and transport anomalies; keep head and enter backoff.
   */
  private static classify(logger: Logger, result: HttpResult): string {
    const code: number = result.statusCode;
    if (code >= 200 && code < 300) {
      try {
        const parsed: Object = JSON.parse(result.body);
        if ((parsed as Record<string, Object>)['result'] !== undefined) return 'success';
        // 2xx without "result" — server or proxy broken; don't spin forever.
        logger.w(`[RequestQueue] classify, 2xx missing "result" — dropping head. body=${RequestQueue.bodyPreview(result.body)}`);
        return 'drop';
      } catch (err) {
        logger.w(`[RequestQueue] classify, 2xx unparseable (${err}) — dropping head. body=${RequestQueue.bodyPreview(result.body)}`);
        return 'drop';
      }
    }
    if (code >= 400 && code < 500) {
      // 4xx is permanent — wrong app_key, bad salt, revoked credentials.
      logger.w(`[RequestQueue] classify, ${code} permanent failure — dropping head. body=${RequestQueue.bodyPreview(result.body)}`);
      return 'drop';
    }
    // 5xx or anomalous code — assume transient, retry with backoff.
    return 'retry';
  }

  private static bodyPreview(body: string): string {
    return body.length > 256 ? `${body.substring(0, 256)}…` : body;
  }

  /**
   * Redact sensitive parameters (device_id, app_key, checksum256) from a
   * request body before it lands in a warning log. This preserves enough
   * structure for debugging (param names, payload shape) while preventing
   * stable identifiers from being exfiltrated via a wired-up log listener.
   */
  private static redactPreview(data: string): string {
    const redacted: string = data
      .replace(/(^|&)device_id=[^&]*/g, '$1device_id=<redacted>')
      .replace(/(^|&)app_key=[^&]*/g, '$1app_key=<redacted>')
      .replace(/(^|&)checksum256=[^&]*/g, '$1checksum256=<redacted>');
    return redacted.length > 256 ? `${redacted.substring(0, 256)}…` : redacted;
  }

  private async persist(): Promise<void> {
    if (!this.config.storage) return;
    const ok: boolean = await this.config.storage.saveRequestQueue(this.queue);
    if (!ok) {
      // Storage write failed — in-memory queue is still authoritative, but
      // the integrator should know requests will be lost on process restart.
      this.config.logger.e('[RequestQueue] persist, saveRequestQueue returned false — queue will be lost on restart');
    }
  }
}
