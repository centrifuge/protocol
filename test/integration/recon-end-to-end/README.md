# End To End Tester

This folder contains the end-to-end invariant suite to test the `Hub` and `Vaults` together.

## Testing 

To run the suite locally use the following command: 
```bash
echidna . --contract CryticPoolTester --config echidna.yaml --format text --workers 16 --test-limit 100000000
```

### Running Reproducers 

#### Locally 
When testing locally if a property is broken, copy and paste it into the [recon scrapper tool](https://getrecon.xyz/tools/echidna) which will generate a Foundry unit test from it. 

#### Recon Cloud Job
When a property breaks for a Recon cloud job a reproducer unit test is automatically generated.

You can then copy and paste the unit test into the `CryticToFoundry` contract to debug the source of individual broken properties. 

## Setup

For more info on the general structure of the test suite, refer to the section of the Recon docs on the [Chimera Framework](https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html).

This setup removes the previously used `GatewayMockTargets` and `VaultCallbackTargets` from the individual vault tester. 

This is because the `fulfillDepositRequest`, `fulfillRedeemRequest`, `fulfillCancelDepositRequest` and `fulfillCancelRedeemRequest` are now called as callbacks through the `MockMessageDispatcher` in their usual flows, whereas previously there were no functions that would trigger these from the `Hub` side.

The core system components are deployed in the `Setup` contract but to introduce additional randomness and test all possible configurations the `TargetFunctions::shortcut_deployNewTokenPoolAndShare` is used to deploy an instance of the `ShareToken`, pool, shareClass and `vault`.

The additional shortcut functions in the `TargetFunctions` contract are meant to make state exploration faster by executing all the necessary calls for a deposit/withdrawal since the multiple steps required with specific values is difficult for the fuzzer to reach.  