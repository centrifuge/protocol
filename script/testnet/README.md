# Testnet Scripts

**Note:** Intended for testnet use only.

## Overview

Test each cross-chain adapter (Axelar, LayerZero, Wormhole, Chainlink) in isolation between Base Sepolia (Hub) and Arbitrum Sepolia (Spoke).

**Test Configuration:**
- Hub: Base Sepolia (centrifugeId: 2)
- Spoke: Arbitrum Sepolia (centrifugeId: 3)
- Adapters: Axelar, LayerZero, Wormhole, Chainlink
- Pool IDs: Configurable via `GAS_TEST_BASE` env var

---

## Automated Orchestration (deploy.py)

Run from `script/deploy/`. All commands read `connectsTo` from the hub's `env/<network>.json` to determine spoke networks.

### Full sequence (recommended for first run)

```bash
python3 deploy.py base-sepolia crosschaintest
```

Executes 4 steps sequentially:

| Step | What it does | XC Messages |
|------|--------------|-------------|
| 1. Spoke registration | Runs `registerAssetOnly()` on each spoke in `connectsTo` | 1 per spoke |
| 2. Hub setup | Runs `runPoolSetup()` + `runAdapterSetup()` on hub | 2 per adapter |
| 3. Wait for relay | Prints explorer links, waits for user confirmation (~5-10 min) | — |
| 4. Share class test | Runs `runShareClassTest()` on hub | 1 per adapter |

### Individual steps

| Command | Description |
|---------|-------------|
| `python3 deploy.py base-sepolia crosschaintest:spoke` | Register assets on all connected spokes |
| `python3 deploy.py base-sepolia crosschaintest:hub` | Run phases 1+2 on hub (pool setup + adapter config) |
| `python3 deploy.py base-sepolia crosschaintest:test` | Run phase 3 on hub (repeatable share class test) |

After the full run, phase 3 can be repeated independently with `crosschaintest:test`.

**CI mode:** When `GITHUB_ACTIONS` is set, step 3 auto-waits instead of prompting (default 600s, override with `XC_RELAY_WAIT`).

---

## Scripts (Manual Usage)

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
- Sets up one-directional communication (source -> destination)
- Wires adapters (Wormhole, LayerZero, Axelar) between networks
- Registers adapters that exist on BOTH source and destination networks

**Usage:**
```bash
export NETWORK=sepolia
forge script script/testnet/WireAdapters.s.sol:WireAdapters --rpc-url $RPC_URL --broadcast -vvvv
```

---

### TestAdapterIsolation.s.sol

Test each cross-chain adapter in isolation. Separates pool setup from adapter configuration, allowing repeated `NotifyShareClass` tests without re-running expensive adapter setup.

**Purpose:**
- Test each adapter in isolation (one pool per adapter)
- Validate that gas estimations are sufficient for cross-chain message execution
- Test `NotifyShareClass` (most expensive static message) repeatedly
- Minimize cost by reusing pool/adapter setup across multiple tests

**Three-Phase Workflow:**

| Phase | Entry Point           | Frequency        | XC Messages                      | Cost         |
| ----- | --------------------- | ---------------- | -------------------------------- | ------------ |
| 1     | `runPoolSetup()`      | Once             | 0                                | Hub gas only |
| 2     | `runAdapterSetup()`   | Once per adapter | 2 (SetPoolAdapters + NotifyPool) | ~0.2 ETH     |
| 3     | `runShareClassTest()` | **Repeatable**   | 1 (NotifyShareClass)             | ~0.1 ETH     |

**Quick Start:**
```bash
# Phase 1: Create pools (hub only, no XC)
NETWORK=base-sepolia forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPoolSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Phase 2: Configure adapters (sends XC messages)
NETWORK=base-sepolia forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAdapterSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Wait for XC relay (~5-10 min)

# Phase 3: Test NotifyShareClass (repeatable!)
NETWORK=base-sepolia forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
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
| Variable          | Default          | Description                            |
| ----------------- | ---------------- | -------------------------------------- |
| `GAS_TEST_BASE`   | 91000            | Base pool index                        |
| `ADAPTER`         | all              | Single adapter: axelar, layerzero, wormhole, chainlink |
| `XC_GAS_PER_CALL` | 0.1 ether        | Gas for each cross-chain call          |
| `SPOKE_NETWORK`   | arbitrum-sepolia | Target spoke network                   |

**Note:** For cross-chain setups, asset registration is optional. If not registered, pools are created without holdings initialization.

---

## Quick Start

```bash
# Set environment
export TESTNET_SAFE_PK="your-private-key"
export RPC_URL="https://sepolia.base.org"
export ARBITRUM_SEPOLIA_RPC="https://sepolia-rollup.arbitrum.io/rpc"

# Step 0: Register asset from spoke (one-time, if not already done)
# Step 1: Create pools on hub (Phase 1)
# Step 2: Configure adapters (Phase 2) + wait for XC relay
# Step 3: Test share class notifications (Phase 3, repeatable)
# Step 4: Verify on spoke
```

---

## Prerequisites

### ETH Requirements

You need ETH on Base Sepolia for:
- Pool subsidies: ~0.1 ETH x 4 pools = 0.4 ETH
- XC gas fees: ~0.01-0.1 ETH per call
- **Total: ~1-2 ETH recommended**

Check balance:
```bash
cast balance 0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb --rpc-url https://sepolia.base.org
```

### Contract Addresses

Contract addresses are deterministic across all chains (CREATE3). Look up the latest addresses in the env config files:

- **Hub (Base Sepolia)**: `env/base-sepolia.json` → `contracts` section
- **Spoke (Arbitrum Sepolia)**: `env/arbitrum-sepolia.json` → `contracts` section

Key contracts: `root`, `hub`, `hubRegistry`, `spoke`, `multiAdapter`, `vaultRegistry`, `axelarAdapter`, `layerZeroAdapter`, `wormholeAdapter`, `chainlinkAdapter`, `subsidyManager`.

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

## Step 1: Create Pools (Phase 1)

Run on Hub (Base Sepolia). Creates one pool per adapter, no cross-chain messages:

```bash
NETWORK=base-sepolia \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPoolSetup()" \
  --fork-url $RPC_URL \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

**What happens:**
1. Creates 4 pools (Axelar, LayerZero, Wormhole, Chainlink)
2. Adds share classes and initializes holdings
3. No cross-chain messages — hub gas only

---

## Step 2: Configure Adapters (Phase 2) + Wait for Relay

```bash
NETWORK=base-sepolia \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAdapterSetup()" \
  --fork-url $RPC_URL \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

**What happens:**
- Calls `hub.setAdapters()` to configure isolated adapter per pool
- Sends `SetPoolAdapters` + `NotifyPool` cross-chain to spoke
- 2 XC messages per adapter

Monitor cross-chain message delivery:
- **Axelar**: https://testnet.axelarscan.io/gmp/search?sourceChain=base-sepolia&destinationChain=arbitrum-sepolia&senderAddress=0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **LayerZero**: https://testnet.layerzeroscan.com/address/0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **Chainlink CCIP**: https://ccip.chain.link/address/0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **Wormhole** (deprecated): https://wormholescan.io/#/txs?address=0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb&network=Testnet

Verify adapter config on spoke (Arbitrum Sepolia):
```bash
# Check Axelar pool (91000) has adapter configured
# Pool ID = (2 << 48) | 91000 = 562949953512312
cast call $MULTI_ADAPTER "quorum(uint16,uint64)(uint8)" 2 562949953512312 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
# Expected: 1 (single adapter)
```

---

## Step 3: Test Share Class (Phase 3, Repeatable)

After adapter config is confirmed on spoke:

```bash
NETWORK=base-sepolia \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runShareClassTest()" \
  --fork-url $RPC_URL \
  --broadcast \
  --private-key $TESTNET_SAFE_PK \
  -vvvv
```

**What happens:**
- Adds a new share class to each pool
- Sends `NotifyShareClass` through the isolated adapter
- Run this repeatedly to test gas estimation with different share classes

---

## Step 4: Verify on Spoke

Wait for cross-chain relay, then verify share tokens exist:

```bash
# Check ShareToken exists on Spoke
# NOTE: HubRegistry.exists() is Hub-only. On Spoke, check ShareToken instead.
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512312 0x00020000000163780000000000000001 \
  --rpc-url $ARBITRUM_SEPOLIA_RPC
# Expected: non-zero ShareToken address

# If you get error 0xd100e440 (ShareTokenDoesNotExist), the message hasn't been processed yet
```

---

## Pool ID Reference

With `GAS_TEST_BASE=91000` (default):

| Adapter   | Pool Index | Pool ID (decimal) | Pool ID (hex)      |
| --------- | ---------- | ----------------- | ------------------ |
| Axelar    | 91000      | 562949953512312   | 0x0002000000016378 |
| LayerZero | 91001      | 562949953512313   | 0x0002000000016379 |
| Wormhole  | 91002      | 562949953512314   | 0x000200000001637a |
| Chainlink | 91003      | 562949953512315   | 0x000200000001637b |

**Formula:** `PoolId = (centrifugeId << 48) | poolIndex`

Calculate manually:
```bash
python3 -c "print((2 << 48) | 91000)"
# Output: 562949953512312
```

---

## Single Adapter Testing

Test a specific adapter in isolation to validate gas estimation and cross-chain message execution.

### Method 1: Named Entry Points (Recommended)

```bash
# Axelar only
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_PoolSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# After XC relay...
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_AdapterSetup()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# Repeatable share class test
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_ShareClassTest()" --fork-url $RPC_URL --broadcast --private-key $TESTNET_SAFE_PK -vvvv

# LayerZero only
forge script ... --sig "runLayerZero_PoolSetup()"
forge script ... --sig "runLayerZero_AdapterSetup()"
forge script ... --sig "runLayerZero_ShareClassTest()"

# Wormhole only
forge script ... --sig "runWormhole_PoolSetup()"
forge script ... --sig "runWormhole_AdapterSetup()"
forge script ... --sig "runWormhole_ShareClassTest()"
```

### Method 2: ADAPTER Environment Variable

```bash
# Run Phase 1 for LayerZero only
ADAPTER=layerzero NETWORK=base-sepolia forge script ... --sig "runPoolSetup()"

# Run Phase 2 for Axelar only
ADAPTER=axelar NETWORK=base-sepolia forge script ... --sig "runAdapterSetup()"
```

**Supported ADAPTER values:**
- `axelar` or `0` - Axelar adapter only
- `layerzero` or `1` - LayerZero adapter only
- `wormhole` or `2` - Wormhole adapter only
- `chainlink` or `3` - Chainlink adapter only
- `all` (default) - All adapters

---

## Fresh Test Run

To run tests with completely fresh pools:

```bash
# Increment GAS_TEST_BASE
GAS_TEST_BASE=92000 forge script ...
```

This avoids any conflicts with previously created pools.

---

## Known Issues

### Chainlink CCIP Gas Limit
Chainlink CCIP has a per-message gas limit (~2M). Phase 3 sends single `NotifyShareClass` messages which stay under this limit.

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
# SUBSIDY_MANAGER address from env/<network>.json → contracts.subsidyManager.address
cast call $SUBSIDY_MANAGER "subsidies(uint64)(uint256)" 562949953512312 --rpc-url $RPC_URL
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
# SPOKE address from env/arbitrum-sepolia.json → contracts.spoke.address
ARBITRUM_RPC="https://sepolia-rollup.arbitrum.io/rpc"

# Axelar (91000)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512312 0x00020000000163780000000000000001 --rpc-url $ARBITRUM_RPC

# LayerZero (91001)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512313 0x00020000000163790000000000000001 --rpc-url $ARBITRUM_RPC

# Wormhole (91002)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512314 0x000200000001637a0000000000000001 --rpc-url $ARBITRUM_RPC

# Chainlink (91003)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512315 0x000200000001637b0000000000000001 --rpc-url $ARBITRUM_RPC
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

- **Axelar**: https://testnet.axelarscan.io/gmp/search?sourceChain=base-sepolia&destinationChain=arbitrum-sepolia&senderAddress=0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **LayerZero**: https://testnet.layerzeroscan.com/address/0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **Chainlink CCIP**: https://ccip.chain.link/address/0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb
- **Wormhole** (deprecated): https://wormholescan.io/#/txs?address=0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb&network=Testnet
