# Recon Fuzzing Suite

## Overview

This suite is seperated into two parts to test necessary functionality in the core contracts as well as the Aggregator.

## Setup

The vault side of the system is deployed in a configuration to only allow interactions on one chain. The `PoolManager`'s `handleTransferShares` and `transferSharesToEVM` are excluded because they would break assumptions about the system behavior which are being tested by the implemented properties. 

Proper testing of these properties in a cross-chain environment requires a full governance fuzzing suite which detects transfer events on one chain and executes calls to `handleTransferShares` and `transferSharesToEVM` with the transferred value.

## Running the tests

This suite is setup for local and forked environment testing. 

### Local Testing

To run the tests locally, you can use the following commands:

#### Core Contracts
```bash
echidna . --contract CryticVaultTester --config echidna.yaml --format text --workers 16 --test-limit 100000000
```

#### Aggregator
```bash
echidna . --contract CryticAggregatorTester --config echidna.yaml
```

### Reproducers 
If a property is found to be violated, the reproducer foundry unit test can be run by copying and pasting the test from the Recon UI into the `CryticToFoundry` contract. 

These tests can then be run using the standard foundry command:

```terminal
forge test --match-test <test_name>
```

### Forked Testing

An additional setup is needed to run the tests in a forked environment. This was added in the `setupFork` function. 

The default forked setup is for the USDC pool deployed on Ethereum Mainnet, but can be changed to any other pool by changing the following variables in the `setupFork` function in:
- `vault`
- `trancheToken`
- `token`
- `poolId`
- `trancheId`
- `currencyId`

This is most easily done using the dynamic replacement feature in the Recon UI with the `5Mil-Vaults-Echidna-Forked` recipe.

The primary downside of performing forked testing in this way is the clamping applied to the functions in the `VaultCallbacks` guarantees that we will always get valid values for the payout parameters. This means we could potentially miss edge cases where the payout parameters are invalid but the request is still fulfilled. This is the primary objective of governance fuzzing, so that we can test if the fulfillments of pending requests always work as expected.

To run the tests in a forked environment first set the environment variables in the `.env` file, then run the following command:

```bash
ECHIDNA_RPC_URL=$(grep ECHIDNA_RPC_URL .env | cut -d'=' -f2) ECHIDNA_RPC_BLOCK=$(grep ECHIDNA_RPC_BLOCK .env | cut -d'=' -f2) echidna . --contract CryticCoreForkedTester --config echidna.yaml
```

To run reproducers from fork fuzzing runs, paste the test from the Recon UI into the `CryticToForkedFoundry` contract and add the `ECHIDNA_RPC_URL` and `ECHIDNA_RPC_BLOCK` variables to the `.env` file. 

These tests can then be run using the standard foundry command:

```terminal
forge test --match-test <test_name>
```

### Governance Fuzzing

Governance fuzzing allows us to test if fulfillments of pending requests are working as expected. 

#### How It Works

Before a pending request is fulfilled, we will use the emitted events to trigger a forked fuzzing job of the current chain state. This fuzzing job will execute the admin call to the function that fulfills the request using the `doGovFuzzing` function.

The properties will then be checked against the fulfilled request.

Normal admin functions aren't be called when using governance fuzzing because they would: 
1. Modify the system configuration in ways that are unrealistic when forking the chain state    
2. Defeat the purpose of governance fuzzing as they would complete fulfillments of pending requests which is what we want to test

This is done using the `notGovFuzzing` modifiers on the admin function handlers.

The following variables need to be set to be dynamically replaced during governance fuzzing:

- `GOV_FUZZING` - this must be set to `true` when using governance fuzzing to prevent admin functions from being called
- `TARGET`
- `DATA`
- `VALUE`
- `GAS`

Change these if not testing the default USDC pool:
- `vault`
- `trancheToken`
- `token`
- `poolId`
- `trancheId`
- `currencyId` 
- `whale` - this must be set to the address of a whale for the `token` that will be used to fund the actors


The following events are emitted to trigger gov fuzzing:

