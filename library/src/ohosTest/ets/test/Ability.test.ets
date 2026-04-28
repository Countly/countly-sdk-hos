import { Hypium } from '@ohos/hypium';
import { abilityDelegatorRegistry } from '@kit.TestKit';
import testsuite from './List.test';

export default function abilityTest() {
  const delegator: abilityDelegator.AbilityDelegator = abilityDelegatorRegistry.getAbilityDelegator();
  const args: abilityDelegator.AbilityDelegatorArgs = abilityDelegatorRegistry.getArguments();
  Hypium.hypiumInit(delegator, args);
  testsuite();
  Hypium.hypiumRun();
}
