import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import i18n from '@ohos.i18n';

/**
 * Collects HarmonyOS device/OS metrics. Values are read lazily and cached per
 * call — values like screen resolution may change over time, so callers pass
 * fresh metric overrides each session.
 */
export class DeviceInfo {
  public static collect(appVersion: string, metricOverride: Record<string, string>): Record<string, string> {
    const out: Record<string, string> = {};
    out['_os'] = 'HarmonyOS';

    try {
      out['_os_version'] = deviceInfo.displayVersion ?? deviceInfo.osFullName ?? 'unknown';
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
      // locale unavailable — omit
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
