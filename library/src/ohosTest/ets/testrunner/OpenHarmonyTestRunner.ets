import hilog from '@ohos.hilog';
import TestRunner from '@ohos.application.testRunner';
import AbilityDelegatorRegistry from '@ohos.app.ability.abilityDelegatorRegistry';

const TAG: string = 'testTag';
const DOMAIN: number = 0x0000;

let abilityDelegator: AbilityDelegatorRegistry.AbilityDelegator | null = null;
let abilityDelegatorArguments: AbilityDelegatorRegistry.AbilityDelegatorArgs | null = null;

async function onAbilityCreateCallback(): Promise<void> {
  hilog.info(DOMAIN, TAG, 'onAbilityCreateCallback');
}

async function addAbilityMonitorCallback(err: Error): Promise<void> {
  hilog.info(DOMAIN, TAG, `addAbilityMonitorCallback: ${JSON.stringify(err) ?? ''}`);
}

export default class OpenHarmonyTestRunner implements TestRunner {
  constructor() {}

  onPrepare(): void {
    hilog.info(DOMAIN, TAG, 'OpenHarmonyTestRunner onPrepare');
  }

  async onRun(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'OpenHarmonyTestRunner onRun start');
    abilityDelegatorArguments = AbilityDelegatorRegistry.getArguments();
    abilityDelegator = AbilityDelegatorRegistry.getAbilityDelegator();
    const testAbilityName: string = `${abilityDelegatorArguments.bundleName}.TestAbility`;
    const monitor: AbilityDelegatorRegistry.AbilityMonitor = {
      abilityName: testAbilityName,
      onAbilityCreate: onAbilityCreateCallback
    };
    abilityDelegator.addAbilityMonitor(monitor, addAbilityMonitorCallback);
    let cmd: string = `aa start -d 0 -a TestAbility -b ${abilityDelegatorArguments.bundleName}`;
    const debugFlag: string | undefined = abilityDelegatorArguments.parameters['-D'];
    if (debugFlag === 'true') {
      cmd += ' -D';
    }
    hilog.info(DOMAIN, TAG, `cmd: ${cmd}`);
    abilityDelegator.executeShellCommand(cmd, (err: Error, data: AbilityDelegatorRegistry.ShellCmdResult) => {
      hilog.info(DOMAIN, TAG, `executeShellCommand err: ${JSON.stringify(err) ?? ''}`);
      hilog.info(DOMAIN, TAG, `executeShellCommand stdResult: ${data.stdResult ?? ''}`);
      hilog.info(DOMAIN, TAG, `executeShellCommand exitCode: ${data.exitCode ?? ''}`);
    });
    hilog.info(DOMAIN, TAG, 'OpenHarmonyTestRunner onRun end');
  }
}
