import { Logger } from '../internal/Logger';
import { ModulePush } from '../internal/modules/ModulePush';
import { MessagingProvider } from '../types/Types';

/**
 * User-facing push-notifications surface — accessed via `Countly.sharedInstance().push`.
 *
 * DISABLED: the push module is intentionally turned off in this build. Method
 * bodies are no-op'd (see logs) and the property on `CountlyInstance` is
 * scoped `private`, so the surface is unreachable from integrator code. The
 * underlying `ModulePush` is still constructed and wired into the lifecycle
 * fan-out so consent / device-id / halt invariants stay symmetric with the
 * rest of the SDK; only the entry points from the public API are gated.
 */
export class PushApi {
  private readonly logger: Logger;
  private readonly module: ModulePush;
  private readonly hasConsent: (feature: string) => boolean;

  constructor(logger: Logger, module: ModulePush, hasConsent: (feature: string) => boolean) {
    this.logger = logger;
    this.module = module;
    this.hasConsent = hasConsent;
  }

  public async onTokenRefresh(token: string, provider: MessagingProvider): Promise<void> {
    this.logger.w('[Push] onTokenRefresh — push module is disabled, no-op');
  }

  public async recordPushNotificationToken(): Promise<void> {
    this.logger.w('[Push] recordPushNotificationToken — push module is disabled, no-op');
  }

  public async clearPushNotificationToken(): Promise<void> {
    this.logger.w('[Push] clearPushNotificationToken — push module is disabled, no-op');
  }

  public async recordPushAction(
    notificationId: string,
    buttonIndex: number,
    url: string | null = null,
    openUrlFn: ((url: string) => void) | null = null
  ): Promise<void> {
    this.logger.w('[Push] recordPushAction — push module is disabled, no-op');
  }

  public async askForNotificationPermission(requester: () => Promise<boolean>): Promise<boolean> {
    this.logger.w('[Push] askForNotificationPermission — push module is disabled, no-op');
    return false;
  }
}
