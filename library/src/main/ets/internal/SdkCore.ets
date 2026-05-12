import { InternalConfig } from './InternalConfig';
import { RequestBuilder } from './RequestBuilder';
import { RequestQueue } from './RequestQueue';
import { ModuleConsent } from './modules/ModuleConsent';
import { ModuleDeviceId } from './modules/ModuleDeviceId';
import { ConsentChangeSource } from '../types/Types';

/**
 * Narrow service surface exposed from the owning CountlyInstance down to
 * individual modules. Using an interface here keeps each module's imports
 * shallow and prevents an import cycle with CountlyInstance.
 *
 * Device-ID and consent reads route through the module references below
 * (`core.consentModule.hasConsent(...)`, `core.deviceIdModule.isTemporary()`)
 * rather than through convenience methods on the core. That keeps the
 * user-facing CountlyInstance surface clean — the public reads live on the
 * `consent` and `deviceId` API facades — without TypeScript's interface
 * implementation rules forcing those methods onto the class.
 */
export interface SdkCore {
  config: InternalConfig;
  requestBuilder: RequestBuilder;
  requestQueue: RequestQueue;

  /** @internal — for module-to-module reads (consent + device id). */
  consentModule: ModuleConsent;
  /** @internal — for module-to-module reads (consent + device id). */
  deviceIdModule: ModuleDeviceId;

  /** Save pending user-profile changes before a request that should include them. */
  saveUserProfileIfPending(): Promise<void>;

  /**
   * Flush in-memory event queue to the request queue. No-op when the queue
   * is empty. Used by ModuleUserProfile to drain events before each
   * user_details enqueue (HOS divergence — see ModuleUserProfile.ets).
   */
  flushEvents(): Promise<void>;

  /**
   * Whether ModuleEvents currently has buffered events. ModuleUserProfile
   * gates its auto-save on this — without events, the per-mutation trigger
   * skips both the flush and the user_details save (HOS divergence).
   */
  hasPendingEvents(): boolean;

  /**
   * Notify modules BEFORE the consent map flips. Resolves once every module's
   * consentWillChange hook has settled, so the caller can then mutate the map
   * with the guarantee that all "stop activity before the flip" work has run.
   */
  notifyConsentWillChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void>;

  /**
   * Notify modules AFTER the consent map has flipped. Resolves once every
   * module's onConsentChanged has settled — ordering between revocation work
   * (e.g. location erasure) and a subsequent consent snapshot is then real.
   */
  notifyConsentDidChange(added: string[], removed: string[], source: ConsentChangeSource): Promise<void>;

  /**
   * Exit unknown consent mode. Called by `ModuleConsent` when the integrator
   * calls `giveConsentAll` / `removeConsentAll` while the instance was started
   * in unknown mode. `givenAll=true` keeps the buffered request queue on disk
   * so a subsequent re-init can ship it; `givenAll=false` drops it.
   * Halts the instance either way — the integrator must call `Countly.haltAll()`
   * (to clear the static handle) and `Countly.initShared(newConfig)` to resume
   * normal operation.
   */
  resolveUnknownConsent(givenAll: boolean): Promise<void>;
}
