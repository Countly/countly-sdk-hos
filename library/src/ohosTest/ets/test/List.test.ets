import utilsTest from './Utils.test';
import loggerTest from './Logger.test';
import requestBuilderTest from './RequestBuilder.test';
import requestQueueTest from './RequestQueue.test';
import consentTest from './Consent.test';
import deviceIdTest from './DeviceId.test';
import eventsTest from './Events.test';
import sessionsTest from './Sessions.test';
import viewsTest from './Views.test';
import crashesTest from './Crashes.test';
import userProfileTest from './UserProfile.test';
import locationTest from './Location.test';
// Push, Content, and Feedback test suites are not registered, the
// underlying modules are disabled in this build (see CountlyInstance.push /
// .content / .feedback being scoped private and the no-op'd APIs). The
// test files stay on disk for a clean re-enable path.
import remoteConfigTest from './RemoteConfig.test';
import healthCheckTest from './HealthCheck.test';
import configurationTest from './Configuration.test';
import countlyFacadeTest from './Countly.test';
import countlyConfigTest from './CountlyConfig.test';
import performanceTest from './Performance.test';
import leakTest from './Leak.test';

export default function testsuite() {
  utilsTest();
  loggerTest();
  requestBuilderTest();
  requestQueueTest();
  consentTest();
  deviceIdTest();
  eventsTest();
  sessionsTest();
  viewsTest();
  crashesTest();
  userProfileTest();
  locationTest();
  remoteConfigTest();
  healthCheckTest();
  configurationTest();
  countlyFacadeTest();
  countlyConfigTest();
  performanceTest();
  leakTest();
}
