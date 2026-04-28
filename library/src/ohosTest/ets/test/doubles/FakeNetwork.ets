import { HttpResult, Network } from '../../../../main/ets/internal/Network';
import { Logger } from '../../../../main/ets/internal/Logger';

export interface RecordedCall {
  endpoint: string;
  data: string;
  usePost: boolean;
  baseUrl: string;
}

/**
 * Test-only Network double. Records every request it's handed and returns a
 * configurable canned response. Lives in the test tree so integrators cannot
 * depend on it by mistake.
 */
export class FakeNetwork extends Network {
  public calls: RecordedCall[] = [];
  public nextStatus: number = 200;
  public nextBody: string = '{"result":"Success"}';
  public nextElapsedMs: number = 20;
  public shouldFail: boolean = false;

  constructor(logger: Logger) {
    super(logger);
  }

  public override async execute(baseUrl: string, endpoint: string, data: string, usePost: boolean): Promise<HttpResult> {
    this.calls.push({ endpoint, data, usePost, baseUrl });
    if (this.shouldFail) {
      throw new Error('FakeNetwork: simulated failure');
    }
    return {
      statusCode: this.nextStatus,
      body: this.nextBody,
      elapsedMs: this.nextElapsedMs
    };
  }

  public reset(): void {
    this.calls = [];
    this.nextStatus = 200;
    this.nextBody = '{"result":"Success"}';
    this.nextElapsedMs = 20;
    this.shouldFail = false;
  }

  public findCallsWithParam(param: string): RecordedCall[] {
    return this.calls.filter((c: RecordedCall) => c.data.indexOf(param) !== -1);
  }
}
