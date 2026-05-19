import { InternalConfig } from './InternalConfig';
import { Utils } from './Utils';
import { DeviceIdType } from '../types/Types';

/**
 * Builds the shared base parameter set every request needs (app_key, device_id,
 * timestamp, sdk metadata, ...). Feature-specific parameters are appended by
 * the individual modules before enqueueing.
 */
export class RequestBuilder {
  private config: InternalConfig;
  private deviceIdProvider: () => string;
  private deviceIdTypeProvider: () => DeviceIdType;

  constructor(config: InternalConfig, deviceIdProvider: () => string, deviceIdTypeProvider: () => DeviceIdType) {
    this.config = config;
    this.deviceIdProvider = deviceIdProvider;
    this.deviceIdTypeProvider = deviceIdTypeProvider;
  }

  public baseParams(): Record<string, string> {
    const ts: number = this.config.clock.nowMs();
    const out: Record<string, string> = {};
    out['app_key'] = this.config.appKey;
    out['device_id'] = this.deviceIdProvider();
    out['t'] = RequestBuilder.deviceIdTypeToWire(this.deviceIdTypeProvider());
    out['timestamp'] = String(ts);
    out['hour'] = String(Utils.hourOf(ts));
    out['dow'] = String(Utils.dayOfWeek(ts));
    out['tz'] = String(Utils.timezoneOffsetMinutes());
    out['sdk_name'] = this.config.sdkName;
    out['sdk_version'] = this.config.sdkVersion;
    // Respect metricOverride['_app_version'] so every request reports the
    // same av that DeviceInfo.collect reports in `metrics`. Without this,
    // integrators overriding _app_version see the override only in the
    // metrics JSON, while av (used for crash/view attribution) still uses
    // the untouched config value, a silent reporting inconsistency.
    const av: string | undefined = this.config.metricOverride['_app_version'];
    out['av'] = (av && av.length > 0) ? av : this.config.appVersion;
    return out;
  }

  /**
   * Build the final query string for a request whose feature-specific params
   * have already been added. Returns the encoded body that will be POSTed (or
   * used as GET query).
   */
  public toQueryString(params: Record<string, string>): string {
    return Utils.buildQueryString(params);
  }

  /**
   * Server "t" source marker per dev guide:
   *   0 = developer-supplied, 1 = SDK-generated, 3 = temporary (offline).
   * Exhaustive switch on the enum, ArkTS will warn if new variants are added
   * without a case here.
   */
  private static deviceIdTypeToWire(type: DeviceIdType): string {
    switch (type) {
      case DeviceIdType.DEVELOPER_SUPPLIED: return '0';
      case DeviceIdType.SDK_GENERATED: return '1';
      case DeviceIdType.TEMPORARY_ID: return '3';
      default: return '1';
    }
  }
}
