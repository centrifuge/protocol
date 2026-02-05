# Testnet Scripts

**Note:** Intended for testnet use only.

## Overview

Test each cross-chain adapter (Axelar, LayerZero, Wormhole) in isolation between Base Sepolia (Hub) and Arbitrum Sepolia (Spoke).

**Test Configuration:**
- Hub: Base Sepolia (centrifugeId: 2)
- Spoke: Arbitrum Sepolia (centrifugeId: 3)
- Adapters: Axelar, LayerZero, Wormhole, Chainlink
- Pool IDs: Configurable via `ADAPTER_TEST_BASE` / `GAS_TEST_BASE` env vars

---

## Scripts

### TestData.s.sol

Standalone script for single-chain deployment and validation.

**Purpose:**
- Deploys a pool and both async/sync vaults on a single network
- Validates full async and sync vault flows (no cross-chain messaging)
- Recommended as a baseline sanity check before running cross-chain flows

**Usage:**
```bash
export NETWORK=sepolia
forge script script/testnet/TestData.s.sol:TestData \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

---

### WireAdapters.s.sol

Configures adapter communication between networks.

**Purpose:**
- Sets up one-directional communication (source → destination)
- Wires adapters (Wormhole, LayerZero, Axelar) between networks
- Registers adapters that exist on BOTH source and destination networks

**Usage:**
```bash
export NETWORK=sepolia
forge script script/testnet/WireAdapters.s.sol:WireAdapters --rpc-url $RPC_URL --broadcast -vvvv
```

---

### TestAdapterIsolation.s.sol

Test each cross-chain adapter in isolation by creating pools with per-pool adapter configuration.

**Purpose:**
- Creates isolated test pools where each pool uses only ONE adapter
- Tests Axelar, LayerZero, and Wormhole adapters independently
- Validates adapter forwarding and message execution without interference

**Prerequisites:**
- Run `deploy.py dump` for the hub network to set environment variables

**Two-Phase Workflow:**
1. **Phase 1: Setup** - Create pools and configure isolated adapters
2. **Phase 2: Operations** - Send pool operations through isolated adapters

---

### TestAdapterGasEstimation.s.sol

**Optimized script for repeated gas estimation testing.** Separates pool setup from adapter configuration, allowing repeated `NotifyShareClass` tests without re-running expensive adapter setup.

**Purpose:**
- Validate that gas estimations are sufficient for cross-chain message execution
- Test `NotifyShareClass` (most expensive static message) repeatedly
- Minimize cost by reusing pool/adapter setup across multiple tests

**Three-Phase Workflow:**

| Phase | Entry Point | Frequency | XC Messages | Cost |
|-------|-------------|-----------|-------------|------|
| 1 | `runPoolSetup()` | Once | 0 | Hub gas only |
| 2 | `runAdapterSetup()` | Once per adapter | 2 (SetPoolAdapters + NotifyPool) | ~0.2 ETH |
| 3 | `runShareClassTest()` | **Repeatable** | 1 (NotifyShareClass) | ~0.1 ETH |

**Comparison with TestAdapterIsolation.s.sol:**
- **Old:** 6 pools × (setup + adapter config) = 6 adapter setups per test round
- **New:** 4 pools × 1 adapter setup + N repeatable share class tests

**Quick Start:**
```bash
# Phase 1: Create pools (hub only, no XC)
NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
  --sig "runPoolSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Phase 2: Configure adapters (sends XC messages)
NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
  --sig "runAdapterSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Wait for XC relay (~5-10 min)

# Phase 3: Test NotifyShareClass (repeatable!)
NETWORK=base-sepolia forge script script/testnet/TestAdapterGasEstimation.s.sol:TestAdapterGasEstimation \
  --sig "runShareClassTest()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Run Phase 3 again to test another share class...
```

**Single Adapter Testing:**
```bash
# Axelar only
forge script ... --sig "runAxelar_PoolSetup()"
forge script ... --sig "runAxelar_AdapterSetup()"
forge script ... --sig "runAxelar_ShareClassTest()"

# Or use ADAPTER env var
ADAPTER=layerzero forge script ... --sig "runPoolSetup()"
```

**Environment Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `GAS_TEST_BASE` | 91000 | Base pool index (different from TestAdapterIsolation) |
| `ADAPTER` | all | Single adapter: axelar, layerzero, wormhole, chainlink |
| `XC_GAS_PER_CALL` | 0.1 ether | Gas for each cross-chain call |
| `SPOKE_NETWORK` | arbitrum-sepolia | Target spoke network |

---

## Quick Start

```bash
# Set environment
export TESTNET_SAFE_PK="your-private-key"
export RPC_URL="https://sepolia.base.org"
export ARBITRUM_SEPOLIA_RPC="https://sepolia-rollup.arbitrum.io/rpc"

# Step 0: Register asset from spoke (one-time, if not already done)
# Step 1: Create pools + configure adapters on Hub
# Step 2: Wait for XC relay (~5-10 min)
# Step 3: Send pool operations
# Step 4: Wait for XC relay (~5-10 min)
# Step 5: Verify vaults on spoke
```

---

## Prerequisites

### ETH Requirements

You need ETH on Base Sepolia for:
- Pool subsidies: ~0.1 ETH × 6 pools = 0.6 ETH
- XC gas fees: ~0.01-0.1 ETH per call
- **Total: ~1-2 ETH recommended**

Check balance:
```bash
cast balance 0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb --rpc-url https://sepolia.base.org
```

### Contract Addresses (Same on All Chains via CREATE3)

```bash
export ROOT=0x8a7c1D479Cc77a5458F74C480B9b306BB29b953e
export MULTI_ADAPTER=0x2C61BC7C5aF7f0Af2888dE9343C3ce4b2fBf5933
export HUB=0xE5e49CEdB5D3DCD24b25e2886a0c5E27e2e9CBe9
export HUB_REGISTRY=0x92e78c7680303b04e4CE9d1736c000288e2339E5
export VAULT_REGISTRY=0x22dB7862f9D903F49CF179C7079E72739f5a3c1D
export SPOKE=0x7Ac5B65764A8b1A19E832FdE942ce618EeF823aF

# Adapters
export AXELAR_ADAPTER=0xb324e55F8332748142274FC76De0A8D95d453Ada
export LAYERZERO_ADAPTER=0x24f3192d46869609F8F6605e662b8146CA4240d3
export WORMHOLE_ADAPTER=0x5940ad8841C50a57F0464f36BaF488964E86655e
```

---

## Step 0: Register Asset (One-Time Setup)

**Only needed if the asset isn't already registered on Hub.**

Asset registration must happen FROM the spoke chain (where the token exists):

```bash
# Run on Arbitrum Sepolia (spoke)
NETWORK=arbitrum-sepolia \
HUB_NETWORK=base-sepolia \
TEST_USDC_ADDRESS=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "registerAssetOnly()" \
  --fork-url $ARBITRUM_SEPOLIA_RPC \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

Wait for XC relay (~5-10 min), then verify on Hub:
```bash
# Check if asset is registered (assetId for Arbitrum USDC)
cast call $HUB_REGISTRY "isRegistered(uint128)(bool)" 15576890575604482885591488987660289 \
  --rpc-url $RPC_URL
# Expected: true
```

---

## Step 1: Create Pools + Configure Adapters

Run Phase 1 on Hub (Base Sepolia):

```bash
NETWORK=base-sepolia \
SKIP_ASSET_REGISTRATION=true \
ADAPTER_TEST_BASE=90100 \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPhase1_Setup()" \
  --fork-url $RPC_URL \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

**Environment Variables:**
| Variable | Default | Description |
|----------|---------|-------------|
| `ADAPTER_TEST_BASE` | 90000 | Base pool index (increment by 100 for fresh pools) |
| `SKIP_ASSET_REGISTRATION` | false | Skip asset registration (set true after Step 0) |
| `XC_GAS_PER_CALL` | 0.1 ether | Gas for each cross-chain call |
| `SPOKE_NETWORK` | arbitrum-sepolia | Target spoke network |

**What happens:**
1. Creates 6 pools (Axelar/LayerZero/Wormhole × Async/Sync)
2. Adds share classes and initializes holdings
3. Calls `hub.setAdapters()` to configure isolated adapters
4. Sends `SetPoolAdapters` cross-chain messages to spoke

---

## Step 2: Wait for XC Relay + Verify

Monitor cross-chain message delivery:
- **Axelar**: https://testnet.axelarscan.io
- **LayerZero**: https://testnet.layerzeroscan.com
- **Wormhole**: https://wormholescan.io/#/?network=TESTNET

Verify adapter config on spoke (Arbitrum Sepolia):
```bash
# Check Axelar Async pool (90100) has adapter configured
# Pool ID = (2 << 48) | 90100 = 562949953511412
cast call $MULTI_ADAPTER "quorum(uint16,uint64)(uint8)" 2 562949953511412 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
# Expected: 1 (single adapter)

cast call $MULTI_ADAPTER "threshold(uint16,uint64)(uint8)" 2 562949953511412 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
# Expected: 1
```

---

## Step 3: Send Pool Operations

After adapter config is confirmed on spoke, run Phase 2:

```bash
NETWORK=base-sepolia \
ADAPTER_TEST_BASE=90100 \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPhase2_Operations()" \
  --fork-url $RPC_URL \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

**What happens:**
- Sends `NotifyPool`, `NotifyShareClass`, `UpdateVault`, price notifications
- Messages route through the isolated adapter for each pool

---

## Step 4: Wait for XC Relay + Verify

Wait for pool operations to be delivered, then verify on spoke:

```bash
# Check ShareToken exists on Spoke (this is the correct check!)
# NOTE: HubRegistry.exists() is Hub-only. On Spoke, check ShareToken instead.
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953511412 0x0002000000015ff40000000000000001 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
# Expected: non-zero ShareToken address (e.g., 0xbcD054C096F5deF41567cd043f58fa5a4dB53FA7)

# If you get error 0xd100e440 (ShareTokenDoesNotExist), the message hasn't been processed yet
```

---

## Pool ID Reference

With `ADAPTER_TEST_BASE=90100`:

| Adapter   | Type  | Pool Index | Pool ID (decimal)   | Pool ID (hex)        |
|-----------|-------|------------|---------------------|----------------------|
| Axelar    | Async | 90100      | 562949953511412     | 0x0002000000015ff4   |
| Axelar    | Sync  | 90101      | 562949953511413     | 0x0002000000015ff5   |
| LayerZero | Async | 90110      | 562949953511422     | 0x0002000000015ffe   |
| LayerZero | Sync  | 90111      | 562949953511423     | 0x0002000000015fff   |
| Wormhole  | Async | 90120      | 562949953511432     | 0x0002000000016008   |
| Wormhole  | Sync  | 90121      | 562949953511433     | 0x0002000000016009   |

**Formula:** `PoolId = (centrifugeId << 48) | poolIndex`

Calculate manually:
```bash
python3 -c "print((2 << 48) | 90100)"
# Output: 562949953511412
```

---

## Single Adapter Testing

Test a specific adapter in isolation to validate gas estimation and cross-chain message execution.

### Method 1: Named Entry Points (Recommended)

```bash
# Axelar only
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_Setup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# After XC relay...
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_Operations()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# LayerZero only
forge script ... --sig "runLayerZero_Setup()"
forge script ... --sig "runLayerZero_Operations()"

# Wormhole only
forge script ... --sig "runWormhole_Setup()"
forge script ... --sig "runWormhole_Operations()"
```

### Method 2: ADAPTER Environment Variable

```bash
# Run Phase 1 for LayerZero only
ADAPTER=layerzero NETWORK=base-sepolia forge script ... --sig "runPhase1_Setup()"

# Run Phase 2 for Axelar only
ADAPTER=axelar NETWORK=base-sepolia forge script ... --sig "runPhase2_Operations()"
```

**Supported ADAPTER values:**
- `axelar` or `0` - Axelar adapter only
- `layerzero` or `1` - LayerZero adapter only
- `wormhole` or `2` - Wormhole adapter only
- `all` (default) - All adapters

---

## Fresh Test Run

To run tests with completely fresh pools:

```bash
# Increment ADAPTER_TEST_BASE by 100
ADAPTER_TEST_BASE=90200 forge script ...
```

This avoids any conflicts with previously created pools.

---

## Known Issues

### Chainlink CCIP Gas Limit
Chainlink CCIP has a per-message gas limit (~2M). When batching multiple messages, the combined gas can exceed this limit, causing `MessageGasLimitTooHigh()`.

**Workaround:** Use `TestAdapterGasEstimation.s.sol` which sends single `NotifyShareClass` messages, staying under the limit.

### Keystore Issues with --account
Using `--account TESTNET_SAFE` can cause simulation issues. Use `--private-key $TESTNET_SAFE_PK` instead.

### Forge Script State
Always use `--fork-url` (not `--rpc-url`) for proper chain state access during simulation.

---

## Troubleshooting

### Check adapter wiring
```bash
cast call $AXELAR_ADAPTER "isWired(uint16)(bool)" 3 --rpc-url $RPC_URL
```

### Check pool subsidy balance
```bash
cast call 0x85b38b923273A604C3cDbcF407DdBFE549346A9a "subsidies(uint64)(uint256)" 562949953511412 --rpc-url $RPC_URL
```

### Debug transaction
```bash
cast receipt <tx-hash> --rpc-url $RPC_URL
cast run <tx-hash> --rpc-url $RPC_URL
```

---

## Verification Commands

### Check ShareToken existence on Spoke

```bash
# Quick check all 6 pools
SPOKE=0x7Ac5B65764A8b1A19E832FdE942ce618EeF823aF
ARBITRUM_RPC="https://sepolia-rollup.arbitrum.io/rpc"

# Axelar Async (90100)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953511412 0x0002000000015ff40000000000000001 --rpc-url $ARBITRUM_RPC

# LayerZero Async (90110)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953511422 0x0002000000015ffe0000000000000001 --rpc-url $ARBITRUM_RPC

# Wormhole Async (90120)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953511432 0x00020000000160080000000000000001 --rpc-url $ARBITRUM_RPC
```

### Check Axelar Message Status

```bash
# Query Axelar GMP API
curl -s "https://testnet.api.gmp.axelarscan.io/searchGMP?txHash=<TX_HASH>" | jq '.data[0] | {status, is_executed}'
```

---

## Adapter Configuration

Edit the network config files (`env/<network>.json`) to control which adapters are deployed:

```json
{
  "adapters": {
    "wormhole": {
      "deploy": true,
      "wormholeId": "10002",
      "relayer": "0x..."
    },
    "layerZero": {
      "deploy": false,
      "endpoint": "0x...",
      "layerZeroEid": 40161
    },
    "axelar": {
      "deploy": true,
      "axelarId": "ethereum-sepolia",
      "gateway": "0x...",
      "gasService": "0x..."
    }
  }
}
```

---

## Monitoring Cross-Chain Messages

- **Axelar**: https://testnet.axelarscan.io
- **Wormhole**: https://wormholescan.io
- **LayerZero**: https://testnet.layerzeroscan.com
