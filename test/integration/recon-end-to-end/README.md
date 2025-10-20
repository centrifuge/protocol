# End To End Tester

This folder contains the end-to-end invariant suite to test the `Hub` and `Vaults` together.

## Testing 

To run the suite locally use the following command: 
```bash
echidna . --contract CryticE2ETester --config echidna.yaml --format text --workers 16 --test-limit 100000000
```

To run the suite on the Recon web app, use the `100mln-e2e-recipe` on the jobs page to have the above command prefilled into the form field.

### Running Reproducers 

#### Locally 
When testing locally if a property is broken, copy and paste it into the [recon scrapper tool](https://getrecon.xyz/tools/echidna) which will generate a Foundry unit test from it. 

#### Recon Cloud Job
When a property breaks for a Recon cloud job a reproducer unit test is automatically generated.

You can then copy and paste the unit test into the `CryticToFoundry` contract to debug the source of individual broken properties. 

## Setup

For info on the general structure of the test suite, refer to the section of the Recon docs on the [Chimera Framework](https://book.getrecon.xyz/writing_invariant_tests/chimera_framework.html).

This tester connects the Vaults and Hub sides of the system via the `MockMessageDispatcher` (which simulates the functionality of the `MessageDispatcher` but removes any cross-chain message sending) allowing full testing of the logic by the fuzzer end-to-end. 

The primary contracts with target functions exposed in this tester are `AsyncVault`, `SyncDepositVault`, `Spoke`, `ShareToken`, `RestrictedTransfers`, `Hub`, `BalanceSheet` and `SyncRequestManager`.

> Note: cross-chain interactions are not tested. 

The core system components are deployed in the `Setup` contract but to introduce additional randomness and test all possible configurations the `TargetFunctions::shortcut_deployNewTokenPoolAndShare` is used to deploy an instance of the pool, shareClass, `ShareToken` and a `SyncDepositVault` or `AsyncVault`.

The `poolId`, `scId`, `assetId`, `shareToken`, `vault` currently being used by the system are handled by the managers in the [managers](https://github.com/centrifuge/protocol-v3/tree/feat/recon-invariants/test/integration/recon-end-to-end/managers) directory. This allows ensuring the same values are used across target functions and properties. See the [recon book](https://book.getrecon.xyz/extra/advanced.html#programmatic-deployment) for more details on how/why this is done.

The primary entrypoint for the fuzzer is via the `VaultTargets` for the Vault side and via the `HubTargets` on the Hub side. Because many of the `Hub` functions are privileged, they are executed using the admin actor in the `AdminTargets`. 

> Note: the `VaultRouter` has been omitted from the setup and the vault functions are therefore called directly on an instance of the vault. 

The setup uses three actors, one `admin` actor (`address(this)`)to call privileged functions and non-privileged function, and two "normal user" actors (`address(0x10000)`,`address(0x20000)`) to call non-privileged functions how an average user might.  

The additional shortcut functions (prefixed with `shortcut_`) in the `TargetFunctions` contract are meant to make state exploration faster by executing all the necessary calls for a deposit/withdrawal since the multiple steps required with specific values is difficult for the fuzzer to reach.  

### Properties

Properties have been implemented in the `Properties` contract as well as in target functions handlers in contracts in the `targets/` folder and are all listed in the [properties table](https://github.com/centrifuge/protocol-v3/blob/feat/recon-invariants/test/integration/recon-end-to-end/properties-table.md). 