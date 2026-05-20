import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import i18n from '@ohos.i18n';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import statvfs from '@ohos.file.statvfs';
import { common } from '@kit.AbilityKit';

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

  /**
   * RAM snapshot for crash metrics ONLY. Android collects RAM (and disk)
   * exclusively inside `getCrashMetricsJSON`, not the session-metrics
   * builder. We mirror that: `collect()` above is the session/RC/etc.
   * metric builder and intentionally does NOT carry `_ram_*`;
   * `ModuleCrashes.recordInternal` calls this method to enrich the crash
   * payload only.
   *
   * Sync because `hidebug.getSystemMemInfo()` is a synchronous /proc
   * read. Returns `_ram_total` / `_ram_current` in MB (server units).
   * On failure (hidebug unavailable in some sandboxed contexts) the
   * record is empty — same "missing rather than zero" contract as the
   * disk path; downstream `_ob` change-detection treats missing keys as
   * "not present" while a "0" string would be a legitimate-looking lie.
   */
  public static collectRamMetrics(): Record<string, string> {
    const out: Record<string, string> = {};
    try {
      const mem: hidebug.SystemMemInfo = hidebug.getSystemMemInfo();
      const totalKb: number = Number(mem.totalMem);
      const availKb: number = Number(mem.availableMem);
      if (Number.isFinite(totalKb) && totalKb > 0) {
        out['_ram_total'] = String(Math.round(totalKb / 1024));
        if (Number.isFinite(availKb) && availKb >= 0) {
          const usedKb: number = totalKb - availKb;
          out['_ram_current'] = String(Math.round(usedKb / 1024));
        }
      }
    } catch (err) {
      // hidebug unavailable, omit silently.
    }
    return out;
  }

  /**
   * Disk metrics for the app sandbox (`context.filesDir`). Async because
   * `statvfs.getTotalSize` ships as a Promise; `getFreeSizeSync` exists
   * but the sync total variant is unconfirmed, so both run async for
   * symmetry. Returns `_disk_total` / `_disk_current` in MB (matches
   * Android units). On any failure (no context, permission, I/O) the
   * returned record is empty and the caller omits the keys, same
   * "missing rather than zero" rule as the RAM path.
   *
   * Like `collectRamMetrics`, this is crash-only — Android does not put
   * disk into session metrics either.
   */
  public static async collectDiskMetrics(context: common.Context | null): Promise<Record<string, string>> {
    const out: Record<string, string> = {};
    if (context === null) return out;
    try {
      const path: string = context.filesDir;
      const total: number = await statvfs.getTotalSize(path);
      const free: number = await statvfs.getFreeSize(path);
      if (Number.isFinite(total) && total > 0) {
        const totalMb: number = Math.round(total / 1048576);
        out['_disk_total'] = String(totalMb);
        if (Number.isFinite(free) && free >= 0) {
          const usedMb: number = Math.round((total - free) / 1048576);
          out['_disk_current'] = String(usedMb);
        }
      }
    } catch (err) {
      // statvfs failure (path invalid, permission denied, fs unmounted), omit.
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
