import { describe, it, expect } from '@ohos/hypium';
import { Logger } from '../../../main/ets/internal/Logger';
import { LogLevel } from '../../../main/ets/types/Types';

class CapturedLog {
  public msg: string;
  public level: LogLevel;
  constructor(msg: string, level: LogLevel) {
    this.msg = msg;
    this.level = level;
  }
}

export default function loggerTest() {
  describe('LoggerTest', () => {
    it('listener_receivesAllLevels_whenMinIsVerbose', 0, () => {
      // The listener is now gated by minLevel (same rule as console) to stop
      // DEBUG/VERBOSE log lines from exfiltrating to cloud log sinks by
      // default. Tests that want to see every level must lower minLevel.
      const logger: Logger = new Logger();
      logger.setMinLevel(LogLevel.VERBOSE);
      const events: CapturedLog[] = [];
      logger.setListener((msg: string, level: LogLevel) => {
        events.push(new CapturedLog(msg, level));
      });
      logger.v('verbose1');
      logger.d('debug1');
      logger.i('info1');
      logger.w('warn1');
      logger.e('error1');
      expect(events.length).assertEqual(5);
      expect(events[4].level).assertEqual(LogLevel.ERROR);
    });

    it('listener_respectsDefaultMinDebug', 0, () => {
      // Default minLevel is DEBUG, VERBOSE is filtered out.
      const logger: Logger = new Logger();
      const events: CapturedLog[] = [];
      logger.setListener((msg: string, level: LogLevel) => {
        events.push(new CapturedLog(msg, level));
      });
      logger.v('should_be_filtered');
      logger.d('kept');
      expect(events.length).assertEqual(1);
      expect(events[0].level).assertEqual(LogLevel.DEBUG);
    });

    it('listener_prefixesFormat', 0, () => {
      // The message text only carries the `[Countly]` brand prefix, the
      // severity tag (`[Info]` etc.) was removed because `console.*` already
      // routes to the right hilog severity and adding it produced double-
      // tagged lines. Listeners get the level via the second arg instead.
      const logger: Logger = new Logger();
      let capturedMsg: string = '';
      let capturedLevel: LogLevel = LogLevel.VERBOSE;
      logger.setListener((msg: string, level: LogLevel) => {
        capturedMsg = msg;
        capturedLevel = level;
      });
      logger.i('something');
      expect(capturedMsg.indexOf('[Countly]') !== -1).assertTrue();
      expect(capturedMsg.indexOf('something') !== -1).assertTrue();
      expect(capturedLevel).assertEqual(LogLevel.INFO);
    });

    it('console_andListener_bothRespectMinLevel', 0, () => {
      const logger: Logger = new Logger();
      logger.setEnabled(true);
      logger.setMinLevel(LogLevel.WARNING);
      let listened: number = 0;
      logger.setListener((_m: string, _l: LogLevel) => { listened++; });
      logger.d('dbg');   // below threshold, neither console nor listener fires
      logger.w('warn');
      expect(listened).assertEqual(1);
    });

    it('listenerThatThrows_doesNotBreakLogger', 0, () => {
      const logger: Logger = new Logger();
      logger.setListener((_m: string) => { throw new Error('boom'); });
      // Must not throw.
      logger.i('msg');
      expect(true).assertTrue();
    });

    // --- ported from Android ModuleLogTests.runAllLogCallsWhileEnabled ---
    it('runAllLogCallsWhileEnabled_doesNotCrash', 0, () => {
      const logger: Logger = new Logger();
      logger.setEnabled(true);
      logger.setMinLevel(LogLevel.VERBOSE);
      logger.v('aa');
      logger.d('bb');
      logger.i('cc');
      logger.w('dd');
      logger.e('ee');
      expect(true).assertTrue();
    });

    // --- ported from Android ModuleLogTests.runAllLogCallsWhileDisabled ---
    it('runAllLogCallsWhileDisabled_doesNotCrash', 0, () => {
      const logger: Logger = new Logger();
      // Default: enabled=false. Console output is silenced; calls must still be
      // no-op-safe.
      logger.v('aa');
      logger.d('bb');
      logger.i('cc');
      logger.w('dd');
      logger.e('ee');
      expect(true).assertTrue();
    });

    // --- listener still fires when console is disabled ---
    // Verified against Logger.log(): the console branch is gated by `enabled`,
    // but the listener branch is not. Both only share the minLevel filter.
    it('listener_firesEvenWhenConsoleDisabled', 0, () => {
      const logger: Logger = new Logger();
      logger.setEnabled(false);
      logger.setMinLevel(LogLevel.VERBOSE);
      let hits: number = 0;
      logger.setListener((_m: string, _l: LogLevel) => { hits++; });
      logger.v('v');
      logger.d('d');
      logger.i('i');
      logger.w('w');
      logger.e('e');
      expect(hits).assertEqual(5);
    });

    // --- minLevel gates all low-severity channels ---
    it('minLevelWarning_dropsVerboseDebugInfo', 0, () => {
      const logger: Logger = new Logger();
      logger.setMinLevel(LogLevel.WARNING);
      const seen: LogLevel[] = [];
      logger.setListener((_m: string, level: LogLevel) => { seen.push(level); });
      logger.v('x');
      logger.d('x');
      logger.i('x');
      logger.w('x');
      logger.e('x');
      expect(seen.length).assertEqual(2);
      expect(seen[0]).assertEqual(LogLevel.WARNING);
      expect(seen[1]).assertEqual(LogLevel.ERROR);
    });

    // --- throwing listener keeps working after the first error is reported ---
    it('throwingListener_suppressesFurtherErrorsButStillInvoked', 0, () => {
      const logger: Logger = new Logger();
      let invocations: number = 0;
      logger.setListener((_m: string, _l: LogLevel) => {
        invocations++;
        throw new Error('still boom');
      });
      logger.i('one');
      logger.i('two');
      logger.i('three');
      // Every call still reached the listener, even though each one threw.
      expect(invocations).assertEqual(3);
    });
  });
}
