import { afterEach, describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness, assertAllRecordedCallsValid, clearTestHarnesses, assertWireOrder } from './TestHelpers';

export default function locationTest() {
  describe('LocationTest', () => {
    afterEach((): void => { try { assertAllRecordedCallsValid(); } finally { clearTestHarnesses(); } });

    it('initialLocation_attachedToBeginSession', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.location.set('US', 'NY', '40.7,-74.0', null);
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      const beg = h.network.findCallsWithParam('begin_session=1')[0];
      expect(beg !== undefined).assertTrue();
      expect(beg.data.indexOf('country_code') !== -1 || beg.data.indexOf('location') !== -1).assertTrue();
    });

    it('disableLocation_sendsErasure', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.location.disableLocation();
      await flushTick(60);
      const hasEmpty: boolean = h.network.calls.some(c => c.data.indexOf('location=&') !== -1 || c.data.endsWith('location='));
      expect(hasEmpty).assertTrue();
    });

    it('setLocation_duringSession_sendsImmediate', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.location.setLocation('US', 'NY', '40.7,-74.0', null);
      await flushTick(60);
      // At least a begin_session + one location-only request
      expect(h.network.calls.length >= 2).assertTrue();
    });

    it('setLocation_respectsConsent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.consent.setRequiresConsent(true); });
      // Let the deferred init-time healthcheck land before snapshotting the
      // call count, otherwise it'd arrive between `before` and the assertion
      // and inflate the diff that should be zero.
      await flushTick(5);
      const before: number = h.network.calls.length;
      await h.instance.location.setLocation('US', 'NY', '40.7,-74.0', null);
      await flushTick(60);
      expect(h.network.calls.length).assertEqual(before);
    });

    /** setLocation fires a request that carries every provided geographic field.
     *  Mirrors the initial-location check but covers the full post-init path. */
    it('setLocation_allFields_presentInRequest', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.location.setLocation('TR', 'Istanbul', '41.0,28.9', '8.8.8.8');
      await flushTick(60);
      // The SDK intentionally drops `ip` from the post-init location request
      // (IP geocoding only makes sense at begin_session), but country_code,
      // city and location=<gps> must all show up.
      const hasCountry: boolean = h.network.calls.some((c) => c.data.indexOf('country_code=TR') !== -1);
      const hasCity: boolean = h.network.calls.some((c) => c.data.indexOf('city=Istanbul') !== -1);
      const hasLoc: boolean = h.network.calls.some((c) => c.data.indexOf('location=41.0') !== -1);
      expect(hasCountry).assertTrue();
      expect(hasCity).assertTrue();
      expect(hasLoc).assertTrue();
    });

    /** disableLocation sends a request with `location=` (empty). Mirrors the
     *  dev-guide erasure contract: server wipes stored location. */
    it('disableLocation_updatesInternalAndSendsErasure', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.location.set('US', 'NY', '40.7,-74.0', null);
      });
      await h.instance.location.disableLocation();
      await flushTick(60);
      expect(h.instance.config.locationDisabled).assertTrue();
      expect(h.instance.config.initialLocationCountry === null).assertTrue();
      expect(h.instance.config.initialLocationCity === null).assertTrue();
      expect(h.instance.config.initialLocationGps === null).assertTrue();
      expect(h.instance.config.initialLocationIp === null).assertTrue();
      const erasure: boolean = h.network.calls.some((c) =>
        c.data.indexOf('location=&') !== -1 || c.data.endsWith('location='));
      expect(erasure).assertTrue();
    });

    /** Null-field permutation, only country supplied. Other fields must not
     *  appear in the request. */
    it('setLocation_onlyCountry', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      const before: number = h.network.calls.length;
      await h.instance.location.setLocation('DE', null, null, null);
      await flushTick(60);
      expect(h.network.calls.length > before).assertTrue();
      const latest = h.network.calls[h.network.calls.length - 1];
      expect(latest.data.indexOf('country_code=DE') !== -1).assertTrue();
      expect(latest.data.indexOf('city=') === -1).assertTrue();
      expect(latest.data.indexOf('location=') === -1 || latest.data.indexOf('location=&') !== -1).assertTrue();
    });

    /** Null-field permutation, only gps. */
    it('setLocation_onlyGps', 0, async () => {
      const h: Harness = await buildHarness();
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.location.setLocation(null, null, '1.0,2.0', null);
      await flushTick(60);
      const hasGps: boolean = h.network.calls.some((c) => c.data.indexOf('location=1.0%2C2.0') !== -1 || c.data.indexOf('location=1.0,2.0') !== -1);
      expect(hasGps).assertTrue();
    });

    /** Null-field permutation, all null is effectively a no-op update
     *  (locationDisabled stays false; no crash). */
    it('setLocation_allNulls_noCrash', 0, async () => {
      const h: Harness = await buildHarness();
      let threw: boolean = false;
      try {
        await h.instance.location.setLocation(null, null, null, null);
      } catch (e) { threw = true; }
      expect(threw).assertFalse();
    });

    /** init-time location consent missing → standalone `location=` erasure
     *  request is enqueued. Mirrors Android sdk/ModuleLocation.java:99-103
     *  (`initFinished` → `performLocationErasure`). */
    it('initConsentMissing_emitsLocationErasureAtInit', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      await flushTick(60);
      // Erasure has empty value `location=` (note: trailing & or end of string,
      // not `location=<gps>`). Filter callouts that carry only the empty form.
      const erasureCalls = h.network.calls.filter((c) =>
        /(?:^|&)location=(?:&|$)/.test(c.data)
      );
      expect(erasureCalls.length).assertLarger(0);
    });

    /** init-time config.location.disable() → locationDisabled=true on
     *  InternalConfig and begin_session carries an empty `location=`. */
    it('initConfig_locationDisabled_propagates', 0, async () => {
      const h: Harness = await buildHarness((cfg) => { cfg.location.disable(); });
      expect(h.instance.config.locationDisabled).assertTrue();
      h.instance.lifecycleForeground();
      await flushTick(60);
      const beg = h.network.findCallsWithParam('begin_session=1')[0];
      expect(beg !== undefined).assertTrue();
      // Empty `location=` erasure should ride with begin_session when disabled.
      expect(beg.data.indexOf('location=') !== -1).assertTrue();
    });

    /** init-time country + city + gps + ip all survive to InternalConfig. */
    it('initConfig_locationAllFields_propagate', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.location.set('JP', 'Tokyo', '35.6,139.7', '1.1.1.1');
      });
      expect(h.instance.config.initialLocationCountry).assertEqual('JP');
      expect(h.instance.config.initialLocationCity).assertEqual('Tokyo');
      expect(h.instance.config.initialLocationGps).assertEqual('35.6,139.7');
      expect(h.instance.config.initialLocationIp).assertEqual('1.1.1.1');
      expect(h.instance.config.locationDisabled).assertFalse();
    });

    /** Consent revocation for `location` fires an empty-location erasure request
     *  (per dev guide). */
    it('consentRevoke_location_sendsErasure', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      const before: number = h.network.calls.length;
      // Revoke location consent → ModuleLocation.onConsentChanged enqueues erasure.
      h.instance.consentModule.removeConsent(['location']);
      await flushTick(120);
      const after: number = h.network.calls.length;
      expect(after > before).assertTrue();
    });

    it('locationWireOrder_consentBeforeBeginSessionBeforeLocation', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true).giveAll();
      });
      h.instance.lifecycleForeground();
      await flushTick(60);
      await h.instance.location.setLocation('US', 'NYC', '40.7,-74.0', null);
      await flushTick(60);
      assertWireOrder(h.network.calls, ['consent=', 'begin_session=1', 'location=']);
    });
  });
}
