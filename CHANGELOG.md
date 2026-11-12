## XX.XX.XX

* Added "CountlyConfig.sdkInternalLimits.setMaxKeyLength(maxKeyLength)" to limit the length of event keys, view names, segmentation keys and custom user property keys. Longer keys are truncated. The default stays 128, and the key length limit of the SDK Behavior Settings overrides it.
* Added method usage and log codes to the SDK health check.
* Log lines now use the levels of the SDK development guide.
* Offline mode now follows the SDK development guide: data is recorded under the placeholder device ID "CLYTemporaryDeviceID" and nothing is sent until offline mode ends. Start in it with "CountlyConfig.deviceId.enableOfflineMode()", and enter or leave it with "countly.deviceId.enableOfflineMode()" and "countly.deviceId.disableOfflineMode(deviceId)".
* Renamed "CountlyConfig.deviceId.enableTemporaryMode()" to "enableOfflineMode()", "countly.deviceId.enableTemporaryIdMode()" to "enableOfflineMode()" and "countly.deviceId.isTemporaryIdMode()" to "isOfflineMode()".
* Removed "CountlyConfig.network.enableOfflineMode()", "countly.requests.enableOfflineMode()" and "countly.requests.disableOfflineMode(deviceId)", which paused the request queue and kept the device ID.
* Entering offline mode at runtime now works like "changeWithoutMerge" to the placeholder device ID: pending data is sent under the current device ID, the session ends and consent is removed.
* Leaving offline mode with "setID", "changeWithoutMerge", "changeWithMerge" or "disableOfflineMode" now only switches to the new device ID: no merge request is sent, the session and consent stay, and the queued requests are sent under the new device ID. "disableOfflineMode()" without a device ID returns to the device ID used before offline mode, or generates one.
* Offline mode now continues at the next start until a device ID is set, instead of a new device ID being generated.
* Calling "disableOfflineMode" outside offline mode is now ignored with a warning.
* Setting "CLYTemporaryDeviceID" as the device ID, in the config or with "setID", "changeWithoutMerge" or "changeWithMerge", now enters offline mode.
* Requests recorded in offline mode now carry the device ID type "t=2", as the SDK development guide defines.

* Mitigated an issue where clearing or filtering the request queue while a request was being sent could delete an unsent request.
* Mitigated an issue where the health check counted the retry pauses after failed requests as backoffs.
* Mitigated an issue where a delivered health check also cleared what was counted while it was on its way.
* Mitigated an issue where the longest run of backoffs in the health check never went above 1.
* Mitigated an issue where the health check was sent while the SDK Behavior Settings turned networking off.
* Mitigated an issue where the health check carried the app version without the "metrics" consent.
* Mitigated an issue where an SDK started in offline mode sent no health check until its next start.
* Mitigated an issue where the SDK Behavior Settings were not fetched after offline mode ended.
* Mitigated an issue where "changeWithMerge" in offline mode sent a merge request for the placeholder device ID and sent the queued requests under the placeholder.
* Mitigated an issue where requests recorded in offline mode were deleted when the SDK started again in offline mode.
* Mitigated an issue where requests that still carried the placeholder device ID at init were deleted. They are now sent under the current device ID.
* Mitigated an issue where a request recorded in offline mode could be sent under the placeholder device ID, at the next start before the stored device ID was read, or while a real device ID was replacing the placeholder.
* Mitigated an issue where remote config could be downloaded, and A/B test requests sent, while requests queued under the placeholder device ID were still waiting to be sent.
* Mitigated an issue where an event could be sent with a negative duration, for example a timed event ended right after it started. A negative duration is now sent as 0.
* Mitigated an issue where calling "Countly.initShared" or "Countly.createInstance" again ignored the new config without a warning.

## 26.1.0

* Initial release of the Countly HarmonyOS SDK (ArkTS).

* Added multi-instance entrypoints on "Countly":
  * "Countly.initShared(config)" / "Countly.sharedInstance()", initShared is smart: returns the cached instance when healthy, auto-replaces it (via "stop()") when the existing one is stopped, halted, or UCM-locked. Single in-process re-init API.
  * "Countly.createInstance(name, config)" / "Countly.getInstance(name)" / "Countly.listInstances()"
  * "Countly.stopAll()", stops every active instance, preserves storage.
  * "Countly.haltAll()", halts every active instance and wipes storage.
  * Each instance owns its own storage, device ID, queues, and HarmonyOS lifecycle subscription.

* Added the "stop" / "halt" lifecycle distinction on "CountlyInstance":
  * "instance.stop()", halts in-memory (drains modules, halts the queue, deregisters lifecycle, cancels timers); persisted storage is preserved.
  * "instance.halt()", does "stop()" then wipes every persisted SDK key. For "user data deletion" flows.
  * Both are idempotent and per-instance isolated, halting one does not affect siblings.

* Added the events API on "countly.events":
  * "recordEvent(key, segmentation, count, sum, duration)"
  * "recordPastEvent(key, segmentation, count, sum, duration, timestamp)"
  * "startEvent(key)" / "endEvent(key, segmentation, count, sum)" / "cancelEvent(key)"

* Added the views API on "countly.views":
  * "startAutoStoppedView(name, segmentation)" / "startView(name, segmentation)"
  * "stopViewWithName(name, segmentation)" / "stopViewWithID(id, segmentation)" / "stopAllViews(segmentation)"
  * "pauseViewWithID(id)" / "resumeViewWithID(id)"
  * "addSegmentationToViewWithID(id, segmentation)" / "addSegmentationToViewWithName(name, segmentation)"
  * "setGlobalViewSegmentation(segmentation)" / "updateGlobalViewSegmentation(segmentation)"
  * "updateOrientation(mode)"

* Added the sessions API on "countly.sessions":
  * "beginSession()" / "updateSession()" / "endSession()"
  * Manual session control and manual hybrid mode via "CountlyConfig.sessions"

* Added the crashes API on "countly.crashes":
  * "addCrashBreadcrumb(record)"
  * "recordHandledException(err, segmentation)" / "recordUnhandledException(err, segmentation)"
  * "setThreadStackProvider(provider)"
  * Global crash filter callback and custom crash segmentation via "CountlyConfig.crashes"

* Added the user profile API on "countly.userProfile":
  * "setProperty(key, value)" / "setProperties(data)"
  * "increment(key)" / "incrementBy(key, value)" / "multiply(key, value)"
  * "saveMax(key, value)" / "saveMin(key, value)" / "setOnce(key, value)"
  * "push(key, value)" / "pushUnique(key, value)" / "pull(key, value)"
  * "save()" / "clear()"
  * Predefined properties: name, username, email, organization, phone, picture, gender, byear

* Added the consent API on "countly.consent":
  * "giveConsentAll()" / "removeConsentAll()"
  * "checkAllConsent()"
  * Init-time configuration via "CountlyConfig.consent.setRequiresConsent(true)" and "giveAll()"

* Added Unknown Consent Mode via "CountlyConfig.consent.enableUnknownConsentMode()". Collects telemetry locally with the queue paused and the network transport silenced; nothing ships until the integrator resolves. The instance keeps running through both paths.
  * "giveConsentAll()", unsilences and resumes; buffered data ships. SDK continues with full consent.
  * "removeConsentAll()", clears the buffered queue, ships a single all-false revocation snapshot, locks runtime consent ("consent is set per init"). Re-init with a new "CountlyConfig" to unlock.
  * Implies "setRequiresConsent(true)".

* Added the device ID API on "countly.deviceId":
  * "setID(deviceId)"
  * "changeWithMerge(deviceId)" / "changeWithoutMerge(deviceId)"
  * "getID()" / "getType()"
  * "isTemporaryIdMode()" / "enableTemporaryIdMode()"

* Added the location API on "countly.location":
  * "setLocation(country, city, gps, ip)" / "disableLocation()"

* Added the remote config API on "countly.remoteConfig":
  * "downloadAllKeys(callback)" / "downloadSpecificKeys(keys, callback)" / "downloadOmittingKeys(keys, callback)"
  * "getValue(key)" / "getValues()"
  * "getValueAndEnroll(key)" / "getAllValuesAndEnroll()"
  * "enrollIntoABTestsForKeys(keys)" / "exitABTestsForKeys(keys)"
  * "registerDownloadCallback(cb)" / "removeDownloadCallback(cb)"
  * "clearAllRemoteConfig()"
  * Automatic triggers, AB enroll-on-download, and value caching via "CountlyConfig.remoteConfig"

* Added the request queue API on "countly.requestQueue":
  * "enableOfflineMode()" / "disableOfflineMode(deviceId)"
  * "flushQueues()"
  * "replaceAllAppKeysInQueueWithCurrentAppKey()" / "removeDifferentAppKeysFromQueue()"
  * "addDirectRequest(parameters)"
  * "recordMetrics(metricOverride)"

* Added automatic lifecycle tracking. Each instance subscribes to HarmonyOS "applicationStateChange" on "init()" and unsubscribes on "stop()" / "halt()". Manual control available via "Countly.lifecycleForegroundAll()" / "lifecycleBackgroundAll()".

* Added automatic view tracking via "CountlyConfig.views.enableAutomaticViewTracking()", with optional short names ("enableAutomaticViewShortNames") and ability exclusions ("setAutomaticViewTrackingExclusions").

* Added automatic orientation tracking (on by default), toggleable via "CountlyConfig.views.setTrackOrientationChanges(enabled)".

* Added SDK Behavior Settings (server-side configuration):
  * Automatic fetch and cache
  * Event and request queue size limits
  * Key and value length limits
  * Tracking control (global, events, views)
  * Automatic view, session, and crash tracking toggles
  * Event and user-property allow/block lists
  * Segmentation allow/block lists, including per-event segmentation filtering

* Added networking configuration on "CountlyConfig.network":
  * "addCustomNetworkRequestHeaders(headers)"
  * "setMaxRequestQueueSize(size)" / "setRequestDropAgeHours(hours)" / "setRequestTimeoutDuration(seconds)"
  * "setHttpPostForced(isForced)"
  * "setParameterTamperingProtectionSalt(salt)"
  * "disableBackoffMechanism()"
  * "enableOfflineMode()" to start the SDK in offline mode
  * "disableHealthCheck()" to opt out of the one-shot health-check report
  * Optional storage and network overrides on "Countly.initShared(config, storageOverride, networkOverride)" and "Countly.createInstance(name, config, storageOverride, networkOverride)"

* Added a configurable logging system:
  * Log levels: error, warning, info, debug, verbose
  * Custom listener via "CountlyConfig.logging.setListener(listener)"

* Added a built-in device metric provider that auto-collects HarmonyOS device metrics, with override support via "CountlyConfig.setMetricOverride(metricOverride)" and an explicit app version via "CountlyConfig.setAppVersion(version)".
