# Centrifuge Pools Invariant Suite

This folder contains the invariant suite for the Centrifuge Pools.

## Testing 

To run the suite use the following command: 
```bash
echidna . --contract CryticPoolTester --config echidna.yaml --format text --workers 16 --test-limit 100000000
```

## Setup

### Target Functions
Because the `PoolManager` functions can only be called via the `PoolRouter`, which calls them via the `execute` function, the target functions in `PoolRouterTargets` use the abi encoding of the `PoolRouter` functions to queue calls in an array. They can then be executed in a single transaction in the `execute_clamped` function which makes all the queued calls and clears the queue.

This allows greater path exploration because the fuzzer would be unlikely to call the functions with the necessary bytes passed directly.  

The interface of the `createHolding` function was changed midway through the engagement to add the `isLiability` parameter. Adding this to the multiple shortcut functions that call this however throws a stack too deep error so as a workaround, this parameter is defined as a global state variable in the `Setup` contract. This variable is then changed by the fuzzer via the `toggle_IsLiability` function.

### Differences From Actual Implementation
The `adapter` set on the `Gateway` is set to the address of a `MockAdapter` in the `Setup` contract. This is a simplification to allow the necessary logic but it shouldn't forward calls made to the `execute` function because these should be made directly via the `PoolRouterTargets` contract.

The current setup uses one instance of the 
`MultiShareClass` if the relationship between pools and Pools is one-to-many, more will need to be added.

The fuzzing suite assumes the `Gateway` behaves correctly as there isn't much interesting logic in it to test as it just forwards messages received from the vaults and send messages to the vault. 

The test suite was therefore setup so that calls that would normally be made by the `Gateway` to the `PoolManager` are made directly by the fuzzer instead so the fuzzer doesn't have to work around message handling in the `Gateway` which is assumed to be correct. The functions that are exposed to the fuzzer to do this are [here](https://github.com/centrifuge/protocol-v3/blob/442cff7f4a4048b228024740c671a020d4222c10/test/hub/fuzzing/recon-hub/targets/AdminTargets.sol#L132-L175).

The `Gateway` was then mocked [here](https://github.com/centrifuge/protocol-v3/blob/feat/recon-invariants/test/hub/fuzzing/recon-hub/mocks/MockGateway.sol) since it's used in the setup and called by the other contracts to send messages back to the vaults side since the more recent changes to the `Gateway` regarding forwarding gas would require a decent amount of changes to the existing test suite that wouldn't actually add any more interesting state exploration because this is just forwarding messages out to the vaults side. 