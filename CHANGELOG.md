## 26.1.0

* Initial release of the Countly HarmonyOS SDK (ArkTS).

* Added multi-instance entrypoints on "Countly":
  * "Countly.initShared(config)" / "Countly.sharedInstance()"
  * "Countly.createInstance(name, config)" / "Countly.getInstance(name)" / "Countly.listInstances()"
  * "Countly.haltAll()"
  * Each instance owns its own storage, device ID, queues, and HarmonyOS lifecycle subscription.

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

* Added Unknown Consent Mode via "CountlyConfig.consent.enableUnknownConsentMode()". When enabled, the SDK collects telemetry locally with the request queue paused and nothing reaches the server until the integrator calls "giveConsentAll()" (preserves the buffered queue for the next init) or "removeConsentAll()" (drops the buffered queue). Either resolution halts the instance that was in unknown mode — the integrator must re-init with their resolved consent configuration to resume normal operation. Implies "setRequiresConsent(true)".

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

* Added automatic lifecycle tracking. Each "CountlyInstance" subscribes to the HarmonyOS "applicationStateChange" event during "init()" and unsubscribes during "halt()". Manual control remains available via "Countly.lifecycleForegroundAll()" and "Countly.lifecycleBackgroundAll()".

* Added automatic view tracking via "CountlyConfig.views.enableAutomaticViewTracking()", with optional short names ("enableAutomaticViewShortNames") and ability exclusions ("setAutomaticViewTrackingExclusions").

* Added automatic orientation tracking (on by default), toggleable via "CountlyConfig.views.setTrackOrientationChanges(enabled)".

* Added SDK Behavior Settings (server-side configuration):
  * Automatic fetch and cache
  * Event and request queue size limits
  * Key and value length limits
  * Tracking control (global, events, views)
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
