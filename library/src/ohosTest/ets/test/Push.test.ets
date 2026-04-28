import { describe, it, expect } from '@ohos/hypium';
import { buildHarness, flushTick, Harness } from './TestHelpers';
import { MessagingProvider, PushTestMode } from '../../../main/ets/types/Types';

export default function pushTest() {
  describe('PushTest', () => {
    it('onTokenRefresh_noConsent_stashesButDoesNotSend', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        // No push consent given — token should stash, not send.
      });
      await h.instance.onTokenRefresh('tok_abc', MessagingProvider.HMS);
      await flushTick(50);
      const tokenCalls = h.network.findCallsWithParam('token_session=1');
      expect(tokenCalls.length).assertEqual(0);
    });

    it('onTokenRefresh_withConsent_sendsTokenSession', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        cfg.consent.setEnabled(['push']);
      });
      await h.instance.onTokenRefresh('tok_xyz', MessagingProvider.HMS);
      await flushTick(80);
      const tokenCalls = h.network.findCallsWithParam('token_session=1');
      expect(tokenCalls.length).assertEqual(1);
      // Harmony token key and HMS provider both present.
      expect(tokenCalls[0].data.indexOf('harmony_token=tok_xyz') !== -1).assertTrue();
      expect(tokenCalls[0].data.indexOf('token_provider=HMS') !== -1).assertTrue();
    });

    it('onTokenRefresh_sameTokenWithinDebounce_skipsSecondSend', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.onTokenRefresh('same_tok', MessagingProvider.HMS);
      await flushTick(50);
      const initial: number = h.network.findCallsWithParam('token_session=1').length;
      await h.instance.onTokenRefresh('same_tok', MessagingProvider.HMS);
      await flushTick(50);
      const afterSecond: number = h.network.findCallsWithParam('token_session=1').length;
      expect(afterSecond).assertEqual(initial);
    });

    it('onTokenRefresh_differentToken_sendsAgain', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.onTokenRefresh('tok_1', MessagingProvider.HMS);
      await flushTick(50);
      await h.instance.onTokenRefresh('tok_2', MessagingProvider.HMS);
      await flushTick(50);
      const calls = h.network.findCallsWithParam('token_session=1');
      expect(calls.length >= 2).assertTrue();
    });

    it('testMode_devProductionTestDistribution_sentAsTestModeParam', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.pushForTest.setTestMode(PushTestMode.DEVELOPMENT);
      });
      await h.instance.onTokenRefresh('tok_dev', MessagingProvider.HMS);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('test_mode=1');
      expect(calls.length).assertEqual(1);
    });

    it('sendTokenAlways_bypassesConsentCheck', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        // No consent, but sendTokenAlways is set — token should still send.
        cfg.pushForTest.setSendPushTokenAlways(true);
      });
      await h.instance.onTokenRefresh('tok_silent', MessagingProvider.HMS);
      await flushTick(60);
      const calls = h.network.findCallsWithParam('token_session=1');
      expect(calls.length).assertEqual(1);
    });

    it('clearPushNotificationToken_sendsEmptyToken', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.onTokenRefresh('tok_to_clear', MessagingProvider.HMS);
      await flushTick(50);
      await h.instance.clearPushNotificationToken();
      await flushTick(50);
      // After clear, token_session request with empty harmony_token= present.
      const hasEmpty: boolean = h.network.calls.some(c =>
        c.data.indexOf('token_session=1') !== -1 && c.data.indexOf('harmony_token=&') !== -1
      );
      expect(hasEmpty).assertTrue();
    });

    it('recordPushAction_recordsInternalEventWithSegmentation', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.recordPushAction('notif_001', 0, null, null);
      await flushTick(80);
      // [CLY]_push_action is immediate-flush, so a request should be visible.
      const calls = h.network.findCallsWithParam('%5BCLY%5D_push_action');
      expect(calls.length >= 1).assertTrue();
      // Segmentation includes notification id 'notif_001'.
      expect(calls[0].data.indexOf('notif_001') !== -1).assertTrue();
    });

    it('recordPushAction_noPushConsent_dropsEvent', 0, async () => {
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
        // No push consent given.
      });
      await h.instance.recordPushAction('notif_blocked', 0, null, null);
      await flushTick(80);
      const calls = h.network.findCallsWithParam('notif_blocked');
      expect(calls.length).assertEqual(0);
    });

    it('recordPushAction_actionHandlerReturningTrue_skipsOpenUrl', 0, async () => {
      let opened: string = '';
      let handlerCalled: boolean = false;
      const h: Harness = await buildHarness((cfg) => {
        cfg.pushForTest.setNotificationActionHandler((_id: string, _idx: number, _url: string) => {
          handlerCalled = true;
          return true; // we handled it — SDK should not open
        });
      });
      await h.instance.recordPushAction('nid', 0, 'https://example.com/deep', (url: string) => { opened = url; });
      await flushTick(80);
      expect(handlerCalled).assertTrue();
      expect(opened).assertEqual('');
    });

    it('recordPushAction_allowedIntentTargets_blocksNonMatchingUrl', 0, async () => {
      let opened: string = '';
      const h: Harness = await buildHarness((cfg) => {
        cfg.pushForTest.setAllowedIntentTargets(['https://trusted.com/']);
      });
      await h.instance.recordPushAction('nid2', 0, 'https://evil.com/page', (url: string) => { opened = url; });
      await flushTick(80);
      expect(opened).assertEqual('');
    });

    it('recordPushAction_allowedIntentTargets_allowsMatchingUrl', 0, async () => {
      let opened: string = '';
      const h: Harness = await buildHarness((cfg) => {
        cfg.pushForTest.setAllowedIntentTargets(['https://trusted.com/']);
      });
      await h.instance.recordPushAction('nid3', 0, 'https://trusted.com/welcome', (url: string) => { opened = url; });
      await flushTick(80);
      expect(opened).assertEqual('https://trusted.com/welcome');
    });

    it('askForNotificationPermission_runsRequesterWhenConsentGiven', 0, async () => {
      let requested: boolean = false;
      const h: Harness = await buildHarness();
      const granted: boolean = await h.instance.askForNotificationPermission(async () => {
        requested = true;
        return true;
      });
      expect(requested).assertTrue();
      expect(granted).assertTrue();
    });

    it('askForNotificationPermission_skipsRequesterWhenNoPushConsent', 0, async () => {
      let requested: boolean = false;
      const h: Harness = await buildHarness((cfg) => {
        cfg.consent.setRequiresConsent(true);
      });
      const granted: boolean = await h.instance.askForNotificationPermission(async () => {
        requested = true;
        return true;
      });
      expect(requested).assertFalse();
      expect(granted).assertFalse();
    });

    it('tokenPersists_surviveRestart', 0, async () => {
      const h: Harness = await buildHarness();
      await h.instance.onTokenRefresh('persist_tok', MessagingProvider.HMS);
      await flushTick(50);
      // Storage should contain the token.
      const dump = h.storage.dump();
      expect(dump['cly_push_token']).assertEqual('persist_tok');
      expect(dump['cly_push_provider']).assertEqual('HMS');
    });
  });
}
