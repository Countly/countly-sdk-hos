import { Logger } from '../internal/Logger';
import { ModuleContent } from '../internal/modules/ModuleContent';

/**
 * User-facing content-zone surface — accessed via `Countly.sharedInstance().content`.
 *
 * DISABLED: the content-zone module is intentionally turned off in this
 * build. Method bodies are no-op'd (see logs) and the property on
 * `CountlyInstance` is scoped `private`, so the surface is unreachable from
 * integrator code. The underlying `ModuleContent` is still constructed and
 * wired into the lifecycle fan-out so consent / device-id / halt invariants
 * stay symmetric with the rest of the SDK; only the entry points from the
 * public API and overlay are gated.
 */
export class ContentApi {
  private readonly logger: Logger;
  private readonly module: ModuleContent;

  constructor(logger: Logger, module: ModuleContent) {
    this.logger = logger;
    this.module = module;
  }

  public async enterContentZone(): Promise<void> {
    this.logger.w('[Content] enterContentZone — content module is disabled, no-op');
  }

  public exitContentZone(): void {
    this.logger.w('[Content] exitContentZone — content module is disabled, no-op');
  }

  public async refreshContentZone(): Promise<void> {
    this.logger.w('[Content] refreshContentZone — content module is disabled, no-op');
  }

  public async previewContent(contentId: string): Promise<void> {
    this.logger.w('[Content] previewContent — content module is disabled, no-op');
  }
}
