import { afterEach, describe, it, expect } from '@ohos/hypium';
import abilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';
import { buildHarness, clearTestHarnesses, flushTick, Harness, parseQueryParams, TestableCountlyConfig } from './TestHelpers';
import { RecordedCall } from './doubles/FakeNetwork';
import { SegmentationMap } from '../../../main/ets/types/Types';

/*
 * In each request scenario the SDK sends the requests api/requests/<scenario>.json records, with the values that change
 * from run to run masked. The scenarios make the calls the other Countly SDKs make in their own request tests. The
 * emulator cannot read the repository, so each scenario prints its record into the aa test log, line by line behind
 * "COUNTLY_REQUEST_RECORD <scenario> ", and .github/scripts/request_records.py compares it with the committed one. A
 * deliberate change: commit the files from the request-records artifact of the device test run, check the difference
 * and add a line to CHANGELOG.md.
 */

const MASK: string = '<masked>';
const MASKED_PARAMS: string[] = ['timestamp', 'hour', 'dow', 'tz', 'sdk_version', 'av', 'rr', 'checksum', 'checksum256', 'session_duration'];
const JSON_PARAMS: string[] = ['events', 'metrics', 'user_details', 'crash', 'consent', 'hc'];
const MASKED_EVENT_FIELDS: string[] = ['timestamp', 'hour', 'dow', 'id', 'pvid', 'cvid', 'peid'];
const MASKED_CRASH_FIELDS: string[] = ['_error', '_run', '_os', '_os_version', '_resolution', '_density', '_locale', '_device', '_device_type', '_manufacturer', '_cpu', '_opengl', '_ram_current', '_ram_total', '_disk_current', '_disk_total', '_bat', '_orientation', '_root', '_online', '_muted', '_background'];
const MAX_INT: number = 2147483647;
const RECORD_PREFIX: string = 'COUNTLY_REQUEST_RECORD ';

/** Whether a parsed JSON value is an object, not an array or a primitive. */
function isObject(value: Object | null): boolean {
  return value !== null && !(value instanceof Array) && typeof value === 'object';
}

/** A copy of a parsed JSON value with the keys of every object sorted, so that the order they are written in does not count. */
function sorted(value: Object | null): Object | null {
  if (value instanceof Array) {
    const list: Array<Object | null> = value as Array<Object | null>;
    const items: Array<Object | null> = [];
    for (let i = 0; i < list.length; i++) {
      items.push(sorted(list[i]));
    }
    return items;
  }
  if (isObject(value)) {
    return masked(value as Record<string, Object | null>, []);
  }
  return value;
}

/** A copy of an object with the values of the given keys masked and the keys of every object sorted. */
function masked(value: Record<string, Object | null>, keys: string[]): Record<string, Object | null> {
  const copy: Record<string, Object | null> = {};
  const names: string[] = Object.keys(value).sort();
  for (let i = 0; i < names.length; i++) {
    copy[names[i]] = keys.indexOf(names[i]) !== -1 ? MASK : sorted(value[names[i]] as Object | null);
  }
  return copy;
}

/** The value of a JSON parameter with the values that change from run to run masked. */
function maskedJson(name: string, value: Object | null): Object | null {
  if ((name === 'metrics' || name === 'hc') && isObject(value)) {
    const fields: Record<string, Object | null> = value as Record<string, Object | null>;
    return masked(fields, Object.keys(fields));
  }
  if (name === 'events' && value instanceof Array) {
    const events: Array<Object | null> = value as Array<Object | null>;
    const items: Array<Object | null> = [];
    for (let i = 0; i < events.length; i++) {
      if (!isObject(events[i])) {
        items.push(sorted(events[i]));
        continue;
      }
      const event: Record<string, Object | null> = events[i] as Record<string, Object | null>;
      items.push(masked(event, event['key'] === '[CLY]_view' ? MASKED_EVENT_FIELDS.concat(['dur']) : MASKED_EVENT_FIELDS));
    }
    return items;
  }
  if (name === 'crash' && isObject(value)) {
    return masked(value as Record<string, Object | null>, MASKED_CRASH_FIELDS);
  }
  return sorted(value);
}

/** The record of the requests the SDK sent: each with its path and its parameters, masked, parsed and sorted. */
function recordOf(calls: RecordedCall[]): string {
  const requests: Array<Record<string, Object | null>> = [];
  for (let i = 0; i < calls.length; i++) {
    const sent: Record<string, string> = parseQueryParams(calls[i].data);
    const names: string[] = Object.keys(sent).sort();
    const params: Record<string, Object | null> = {};
    for (let j = 0; j < names.length; j++) {
      const value: string = sent[names[j]];
      if (MASKED_PARAMS.indexOf(names[j]) !== -1) {
        params[names[j]] = MASK;
      } else if (JSON_PARAMS.indexOf(names[j]) !== -1 && value.length > 0) {
        params[names[j]] = maskedJson(names[j], JSON.parse(value) as Object | null);
      } else {
        params[names[j]] = value;
      }
    }
    const request: Record<string, Object | null> = {};
    request['path'] = calls[i].endpoint.split('?')[0];
    request['params'] = params;
    requests.push(request);
  }
  return JSON.stringify(requests, null, 2) + '\n';
}

/** Prints a record into the aa test log, one line of it per print, for the host to pick up. */
function printRecord(name: string, record: string): void {
  const delegator: abilityDelegatorRegistry.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  const lines: string[] = record.split('\n');
  // the record ends with a line break, so the last piece is empty
  for (let i = 0; i < lines.length - 1; i++) {
    delegator.printSync(RECORD_PREFIX + name + ' ' + lines[i]);
  }
}

/**
 * Moves the recorded events into the request queue and waits until the SDK has sent everything it queued: the queue is
 * empty and no request came for half a second.
 */
async function settle(h: Harness): Promise<void> {
  await h.instance.flushEvents();
  const started: number = Date.now();
  let count: number = -1;
  let quietSince: number = started;
  while (Date.now() - started < 10000) {
    await flushTick(50);
    if (h.instance.requestQueue.size() > 0 || h.network.calls.length !== count) {
      count = h.network.calls.length;
      quietSince = Date.now();
    } else if (Date.now() - quietSince > 500) {
      return;
    }
  }
  throw new Error('the SDK still had requests to send after 10 seconds');
}

/** Runs a scenario on a new SDK instance and prints the record of the requests it sent. */
async function runScenario(name: string, configure: ((cfg: TestableCountlyConfig) => void) | null, scenario: (h: Harness) => Promise<void>): Promise<void> {
  const h: Harness = await buildHarness((cfg: TestableCountlyConfig) => {
    cfg.appKey = 'parity-app-key';
    cfg.serverUrl = 'https://parity.example';
    cfg.deviceId.setId('parity-device-001');
    cfg.sessions.enableManualControl();
    if (configure !== null) {
      configure(cfg);
    }
  });
  // the init requests go out first, so the scenario's own cannot come between them
  await settle(h);
  await scenario(h);
  await settle(h);
  printRecord(name, recordOf(h.network.calls));
  await h.instance.halt();
  expect(h.network.calls.length > 0).assertTrue();
}

/**
 * The event segmentation of the parity scenario, with one value of every type the SDK takes; it has no type for the
 * nested object, the mixed list and the list of objects of the other SDKs' scenarios.
 */
function paritySegmentation(): SegmentationMap {
  const segmentation: SegmentationMap = {
    'nar': 'uto',
    'sasuke': MAX_INT,
    'sakura': false,
    'itachi': Number.MAX_VALUE,
    'kakaski': Number.MIN_VALUE,
    'hashirama': -MAX_INT,
    'stringList': ['value1', 'value2', 'value3'],
    'intList': [1, 2, 3],
    'doubleList': [1.1, 2.2, 3.3],
    'boolList': [true, false, true]
  };
  return segmentation;
}

export default function requestScenariosTest() {
  describe('RequestScenariosTest', () => {
    afterEach((): void => { clearTestHarnesses(); });

    it('parity', 0, async () => {
      await runScenario('parity', null, async (h: Harness): Promise<void> => {
        await h.instance.sessions.beginSession();
        await h.instance.events.recordEvent('purchase', paritySegmentation(), 2, 9.99, 5);
        const properties: SegmentationMap = {
          'name': 'John Doe',
          'username': 'john_d',
          'email': 'john@example.com',
          'organization': 'Countly',
          'phone': '1234567890',
          'picture': 'https://example.com/picture.jpg',
          'gender': 'M',
          'byear': 1980,
          'tier': 'gold',
          'age': 30
        };
        h.instance.userProfile.setProperties(properties);
        await h.instance.userProfile.save();
        // a session update reports elapsed seconds, so at least one has to pass for it to be sent
        await flushTick(1100);
        await h.instance.sessions.updateSession();
        await h.instance.sessions.endSession();
      });
    });

    it('views', 0, async () => {
      await runScenario('views', null, async (h: Harness): Promise<void> => {
        await h.instance.sessions.beginSession();
        const segmentation: SegmentationMap = { 'source': 'scenario' };
        await h.instance.views.startView('Home', segmentation);
        await h.instance.views.stopViewWithName('Home');
        await h.instance.views.startView('Settings');
        await h.instance.sessions.endSession();
      });
    });

    it('crash', 0, async () => {
      await runScenario('crash', null, async (h: Harness): Promise<void> => {
        h.instance.crashes.addCrashBreadcrumb('breadcrumb one');
        const segmentation: SegmentationMap = { 'tier': 'gold' };
        await h.instance.crashes.recordHandledException(new Error('parity crash'), segmentation);
      });
    });

    it('consent', 0, async () => {
      await runScenario('consent', (cfg: TestableCountlyConfig): void => { cfg.consent.setRequiresConsent(true); },
        async (h: Harness): Promise<void> => {
          h.instance.consentModule.giveConsent(['sessions', 'events']);
          await h.instance.sessions.beginSession();
          await h.instance.events.recordEvent('consented');
          await settle(h);
          h.instance.consentModule.removeConsent(['events']);
          await h.instance.events.recordEvent('not_consented');
          await h.instance.sessions.endSession();
        });
    });

    it('device-id', 0, async () => {
      await runScenario('device-id', null, async (h: Harness): Promise<void> => {
        await h.instance.sessions.beginSession();
        await h.instance.deviceId.changeWithMerge('parity-device-002');
        await h.instance.events.recordEvent('after_merge');
        await settle(h);
        await h.instance.deviceId.changeWithoutMerge('parity-device-003');
        await h.instance.events.recordEvent('after_new_id');
        await h.instance.sessions.endSession();
      });
    });
  });
}
