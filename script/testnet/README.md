# Testnet Scripts

**Note:** Intended for testnet use only.

## Overview

Test each cross-chain adapter (Axelar, LayerZero, Chainlink) in isolation between a hub and one spoke. Any
connected testnet pair works; the examples below use Base Sepolia as hub.

**Test Configuration:**
- Hub: whichever network the RPC points at (Base Sepolia in the examples, centrifugeId 2)
- Spoke: the hub's first connected network, or `SPOKE_NETWORK` / the third script argument
- Adapters: Axelar, LayerZero, Chainlink, Hyperlane
- Pool IDs: Configurable via `GAS_TEST_BASE` env var

---

## Automated Orchestration (crosschaintest.sh)

Run from the repository root. The spokes are resolved by `EnvConnections.connectionsWith`, so the rules in
`env/connections/<environment>.json` are interpreted in exactly one place.

**One spoke is tested per run.** The point is isolating each adapter, not covering the topology, so a second
spoke multiplies cost without adding signal. Step 1 registers the asset on every connected spoke (cheap
groundwork that lets you retest against any of them), while steps 2 and 4 drive the hub against the single
spoke under test — by default the hub's first connected network, or a third argument to choose it. A spoke
that is not connected to the hub is rejected, and the hub can never be its own spoke.

### Full sequence (recommended for first run)

```bash
./script/testnet/crosschaintest.sh base-sepolia
```

Executes 4 steps sequentially:

| Step | What it does | XC Messages |
|------|--------------|-------------|
| 1. Spoke registration | Runs `registerAssetOnly()` on each connected spoke | 1 per spoke |
| 2. Hub setup | Runs `runPoolSetup()` + `runAdapterSetup()` on hub | 2 per adapter |
| 3. Wait for relay | Prints explorer links, waits for user confirmation (~5-10 min) | — |
| 4. Share class test | Runs `runShareClassTest()` on hub | 1 per adapter |

### Individual steps

| Command | Description |
|---------|-------------|
| `./script/testnet/crosschaintest.sh base-sepolia spoke` | Register assets on all connected spokes |
| `./script/testnet/crosschaintest.sh base-sepolia hub` | Run phases 1+2 on hub (pool setup + adapter config) |
| `./script/testnet/crosschaintest.sh base-sepolia test` | Run phase 3 on hub (repeatable share class test) |
| `./script/testnet/crosschaintest.sh base-sepolia hub hyper-evm-testnet` | Same, against a chosen spoke |

Steps 2 and 4 must name the same spoke: phase 3 notifies a share class for a pool that phase 2 created for
that pair, so `test` against a spoke you never ran `hub` for will revert.

After the full run, phase 3 can be repeated independently with the `test` mode.

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
forge script script/testnet/TestData.s.sol:TestData \
  --rpc-url sepolia \
  --private-key $PRIVATE_KEY \
  --broadcast \
  -vvvv
```

---

### WireAdapters.s.sol

Configures adapter communication between networks. **Not part of a normal deployment** — `LaunchDeployer`
wires everything itself, from the action batchers, so `deploy-testnets.yml` does not run this. Reach for it
when an existing deployment needs re-wiring without being redeployed: after adding a network to
`env/connections/testnet.json`, or when a chain's adapter address has drifted from the others (as happens
when an adapter is deployed on its own by `script/ops/DeployAdapters.s.sol`, which uses a different salt).

Unlike the batchers, it reads each remote adapter's address out of `env/<remote>.json` rather than assuming
it matches the local one — which is exactly why it can repair a mismatch the batchers would reproduce.

**Purpose:**
- Sets up one-directional communication (source -> destination); run it on each network separately
- Wires adapters (LayerZero, Axelar, Chainlink) between networks
- Registers adapters that exist on BOTH source and destination networks

**Usage:**
```bash
forge script script/testnet/WireAdapters.s.sol:WireAdapters \
  --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast -vvvv
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

The hub is whichever network `--rpc-url` points at — there is no network env var. The spoke defaults to the
hub's first connected network; `SPOKE_NETWORK` names a different one.

```bash
# Phase 1: Create pools (hub only, no XC)
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPoolSetup()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# Phase 2: Configure adapters (sends XC messages)
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAdapterSetup()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# Wait for XC relay (~5-10 min)

# Phase 3: Test NotifyShareClass (repeatable!)
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runShareClassTest()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# Run Phase 3 again to test another share class...
```

**Single Adapter Testing:**
```bash
# Axelar only
forge script ... --sig "runAxelar_PoolSetup()"
forge script ... --sig "runAxelar_AdapterSetup()"
forge script ... --sig "runAxelar_ShareClassTest()"

# Or use ADAPTER env var
ADAPTER=layerzero forge script ... --sig "runPoolSetup()" --rpc-url base-sepolia
```

**Environment Variables:**
| Variable          | Default          | Description                            |
| ----------------- | ---------------- | -------------------------------------- |
| `GAS_TEST_BASE`   | 91000            | Base pool index                        |
| `ADAPTER`         | all              | Single adapter: axelar, layerzero, chainlink, hyperlane |
| `XC_GAS_PER_CALL` | 0.1 ether        | Gas for each cross-chain call          |
| `SPOKE_NETWORK`   | hub's first connected network | Target spoke network. Must differ from the hub and be connected to it in `env/connections/`; both are enforced |

**Note:** For cross-chain setups, asset registration is optional. If not registered, pools are created without holdings initialization.

---

## Quick Start

```bash
# Secrets, including PRIVATE_KEY, into .env — which forge loads by itself
./script/setup/load-secrets.sh
set -a; . ./.env; set +a

# Networks are named, not URLs: `--rpc-url base-sepolia` resolves through foundry.toml [rpc_endpoints]

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
cast balance 0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb --rpc-url base-sepolia
```

### Contract Addresses

Contract addresses are deterministic across all chains (CREATE3). Look up the latest addresses in the env config files:

- **Hub (Base Sepolia)**: `env/base-sepolia.json` → `contracts` section
- **Spoke (Arbitrum Sepolia)**: `env/arbitrum-sepolia.json` → `contracts` section

Key contracts: `root`, `hub`, `hubRegistry`, `spoke`, `multiAdapter`, `vaultRegistry`, `axelarAdapter`, `layerZeroAdapter`, `chainlinkAdapter`, `subsidyManager`.

---

## Step 0: Register Asset (One-Time Setup)

**Only needed if the asset isn't already registered on Hub.**

Asset registration must happen FROM the spoke chain (where the token exists):

```bash
# Run on Arbitrum Sepolia (spoke). HUB_NETWORK names the hub, since the RPC now names the spoke
HUB_NETWORK=base-sepolia \
TEST_USDC_ADDRESS=0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d \
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "registerAssetOnly()" \
  --rpc-url arbitrum-sepolia \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

Wait for XC relay (~5-10 min), then verify on Hub:
```bash
# Check if asset is registered (assetId for Arbitrum USDC)
cast call $HUB_REGISTRY "isRegistered(uint128)(bool)" 15576890575604482885591488987660289 \
  --rpc-url base-sepolia
# Expected: true
```

---

## Step 1: Create Pools (Phase 1)

Run on Hub (Base Sepolia). Creates one pool per adapter, no cross-chain messages:

```bash
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runPoolSetup()" \
  --rpc-url base-sepolia \
  --broadcast \
  --private-key $PRIVATE_KEY \
  -vvvv
```

**What happens:**
1. Creates 4 pools (Axelar, LayerZero, Chainlink, Hyperlane)
2. Adds share classes and initializes holdings
3. No cross-chain messages — hub gas only

---

## Step 2: Configure Adapters (Phase 2) + Wait for Relay

```bash
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAdapterSetup()" \
  --rpc-url base-sepolia \
  --broadcast \
  --private-key $PRIVATE_KEY \
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
- **Hyperlane**: https://explorer.hyperlane.xyz/?search=0xc1A929CBc122Ddb8794287D05Bf890E41f23c8cb

Verify adapter config on spoke (Arbitrum Sepolia):
```bash
# Check Axelar pool (91000) has adapter configured
# Pool ID = (2 << 48) | 91000 = 562949953512312
cast call $MULTI_ADAPTER "quorum(uint16,uint64)(uint8)" 2 562949953512312 \
  --rpc-url arbitrum-sepolia
# Expected: 1 (single adapter)
```

---

## Step 3: Test Share Class (Phase 3, Repeatable)

After adapter config is confirmed on spoke:

```bash
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runShareClassTest()" \
  --rpc-url base-sepolia \
  --broadcast \
  --private-key $PRIVATE_KEY \
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
  --rpc-url arbitrum-sepolia
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
| Chainlink | 91002      | 562949953512314   | 0x000200000001637a |
| Hyperlane | 91003      | 562949953512315   | 0x000200000001637b |

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
  --sig "runAxelar_PoolSetup()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# After XC relay...
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_AdapterSetup()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# Repeatable share class test
forge script script/testnet/TestAdapterIsolation.s.sol:TestAdapterIsolation \
  --sig "runAxelar_ShareClassTest()" --rpc-url base-sepolia --broadcast --private-key $PRIVATE_KEY -vvvv

# LayerZero only
forge script ... --sig "runLayerZero_PoolSetup()"
forge script ... --sig "runLayerZero_AdapterSetup()"
forge script ... --sig "runLayerZero_ShareClassTest()"
```

### Method 2: ADAPTER Environment Variable

```bash
# Run Phase 1 for LayerZero only
ADAPTER=layerzero forge script ... --sig "runPoolSetup()" --rpc-url base-sepolia

# Run Phase 2 for Axelar only
ADAPTER=axelar forge script ... --sig "runAdapterSetup()" --rpc-url base-sepolia
```

**Supported ADAPTER values:**
- `axelar` or `0` - Axelar adapter only
- `layerzero` or `1` - LayerZero adapter only
- `chainlink` or `2` - Chainlink adapter only
- `hyperlane` or `3` - Hyperlane adapter only
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
Using `--account TESTNET_SAFE` can cause simulation issues. Use `--private-key $PRIVATE_KEY` instead, which
`./script/setup/load-secrets.sh` puts in `.env`.

---

## Troubleshooting

`cast` resolves the same `[rpc_endpoints]` aliases as `forge script`, so these take a network name too.

### Check adapter wiring
```bash
cast call $AXELAR_ADAPTER "isWired(uint16)(bool)" 3 --rpc-url base-sepolia
```

### Check pool subsidy balance
```bash
# SUBSIDY_MANAGER address from env/<network>.json → contracts.subsidyManager.address
cast call $SUBSIDY_MANAGER "subsidies(uint64)(uint256)" 562949953512312 --rpc-url base-sepolia
```

### Debug transaction
```bash
cast receipt <tx-hash> --rpc-url base-sepolia
cast run <tx-hash> --rpc-url base-sepolia
```

---

## Verification Commands

### Check ShareToken existence on Spoke

```bash
# SPOKE address from env/arbitrum-sepolia.json → contracts.spoke.address
# Axelar (91000)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512312 0x00020000000163780000000000000001 --rpc-url arbitrum-sepolia

# LayerZero (91001)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512313 0x00020000000163790000000000000001 --rpc-url arbitrum-sepolia

# Chainlink (91003)
cast call $SPOKE "shareToken(uint64,bytes16)(address)" 562949953512315 0x000200000001637b0000000000000001 --rpc-url arbitrum-sepolia
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
