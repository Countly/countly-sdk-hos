/**
 * SDK internal limits. Defaults come from the SDK dev guide; some are
 * overridable via SDK Behavior Settings from the server.
 */
export class Limits {
  public maxKeyLength: number = 128;
  public maxValueSize: number = 256;
  public maxSegmentationValues: number = 100;
  public maxBreadcrumbCount: number = 100;
  public maxStackTraceLinesPerThread: number = 30;
  public maxStackTraceLineLength: number = 200;
  public maxStackTraceThreadCount: number = 50;
}
