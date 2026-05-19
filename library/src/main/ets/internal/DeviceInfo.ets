import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import i18n from '@ohos.i18n';

/**
 * Collects HarmonyOS device/OS metrics. Values are read lazily and cached per
 * call, values like screen resolution may change over time, so callers pass
 * fresh metric overrides each session.
 */
export class DeviceInfo {
  public static collect(appVersion: string, metricOverride: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    out['_os'] = 'HarmonyOS';

    try {
      // Compose the specific OS version from
      // `majorVersion.seniorVersion.featureVersion` (e.g. "6.0.2"). That's
      // the actual user-installed OS version. Other candidates were
      // rejected:
      //   - `displayVersion` is marketing text with device-class prefix
      //     and internal build code (e.g. "emulator
      //     6.0.0.130(SP7DEVC00E130R4P11)") — not a real OS version.
      //   - `distributionOSVersion` returns the broader distribution line
      //     (e.g. "6.0.0") not the specific build the user has installed
      //     (e.g. "6.0.2").
      //   - `osFullName` varies (OpenHarmony vs HarmonyOS) and is verbose.
      // Fallback to `osFullName` then "unknown" if the numeric fields are
      // unavailable.
      const major: number | undefined = deviceInfo.majorVersion;
      const senior: number | undefined = deviceInfo.seniorVersion;
      const feature: number | undefined = deviceInfo.featureVersion;
      if (typeof major === 'number' && typeof senior === 'number' && typeof feature === 'number') {
        out['_os_version'] = `${major}.${senior}.${feature}`;
      } else {
        out['_os_version'] = deviceInfo.osFullName ?? 'unknown';
      }
    } catch (err) {
      out['_os_version'] = 'unknown';
    }

    try {
      out['_device'] = deviceInfo.productModel ?? 'unknown';
    } catch (err) {
      out['_device'] = 'unknown';
    }

    try {
      out['_manufacturer'] = deviceInfo.manufacture ?? 'unknown';
    } catch (err) {
      out['_manufacturer'] = 'unknown';
    }

    try {
      const displayClass: display.Display = display.getDefaultDisplaySync();
      out['_resolution'] = `${displayClass.width}x${displayClass.height}`;
      out['_density'] = String(displayClass.densityDPI);
    } catch (err) {
      // display unavailable in non-UI contexts (e.g. service ability)
    }

    try {
      out['_locale'] = i18n.System.getSystemLocale();
    } catch (err) {
      // locale unavailable, omit
    }

    try {
      out['_device_type'] = DeviceInfo.mapDeviceType(deviceInfo.deviceType);
    } catch (err) {
      out['_device_type'] = 'mobile';
    }

    out['_app_version'] = appVersion;

    // Apply overrides last so integrators can replace any auto-detected value.
    const overrideKeys: string[] = Object.keys(metricOverride);
    for (let i = 0; i < overrideKeys.length; i++) {
      const k: string = overrideKeys[i];
      out[k] = metricOverride[k];
    }
    return out;
  }

  private static mapDeviceType(t: string): string {
    switch (t) {
      case 'phone': return 'mobile';
      case 'tablet': return 'tablet';
      case 'tv': return 'smarttv';
      case 'pc': return 'desktop';
      case 'wearable': return 'mobile';
      default: return 'mobile';
    }
  }
}
