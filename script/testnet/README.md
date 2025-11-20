# Cross-Chain Testing
**Note:** Intended for testnet use only.
All cross-chain testing is now handled through the Python deployment wrapper.

## Overview

Cross-chain testing involves:
1. **Adapter Configuration**: Setting up which adapters (Wormhole, LayerZero, Axelar) are deployed and enabled
2. **Adapter Wiring**: Configuring adapters to communicate between networks
3. **Cross-Chain Tests**: Running tests that send messages between chains

## Adapter Configuration

### Configuring Adapters
Edit the network config files (`env/<network>.json`) to control which adapters are deployed:

```json
{
  "adapters": {
    "wormhole": {
      "deploy": true,    // Deploy WormholeAdapter
      "wormholeId": "10002",
      "relayer": "0x..."
    },
    "layerZero": {
      "deploy": false,   // Skip LayerZeroAdapter
      "endpoint": "0x...",
      "layerZeroEid": 40161
    },
    "axelar": {
      "deploy": true,   // Deploy AxelarAdapter
      "axelarId": "ethereum-sepolia",
      "gateway": "0x...",
      "gasService": "0x..."
    }
  }
}
```

### Wiring Adapters
After configuring adapters, wire them across networks:

```bash
# Wire adapters for a specific network and its connected networks
python3 script/deploy/deploy.py sepolia wire:all

# Wire adapters for a single network only
python3 script/deploy/deploy.py arbitrum-sepolia wire
```

## Cross-Chain Testing

### Hub Test (Creates pools and sends cross-chain messages)
```bash
# Run hub test on arbitrum-sepolia (sends messages to sepolia, base-sepolia)
python3 script/deploy/deploy.py arbitrum-sepolia crosschaintest:hub
```

### Spoke Tests (Interacts with cross-chain vaults)
```bash
# Run spoke test on sepolia (interacts with vaults created by hub)
python3 script/deploy/deploy.py sepolia crosschaintest:spoke
```

## Complete Workflow

### 1. Deploy Protocol (if not already deployed)
```bash
# Deploy to all testnets (includes TestData automatically)
VERSION=v3.1.4 python3 script/deploy/deploy.py deploy:testnets
```

### 2. Configure and Wire Adapters
```bash
# Edit adapter configs in env/<network>.json files
# Then wire all connected networks
python3 script/deploy/deploy.py sepolia wire:all
```

### 3. Run Cross-Chain Tests
```bash
# Run hub test (creates pools, sends cross-chain messages)
python3 script/deploy/deploy.py arbitrum-sepolia crosschaintest:hub

# Run spoke tests (interacts with cross-chain vaults)
python3 script/deploy/deploy.py sepolia crosschaintest:spoke
python3 script/deploy/deploy.py base-sepolia crosschaintest:spoke
```

# Wait for message relay (2-5 minutes)
# Monitor: https://testnet.axelarscan.io

## TestData

**Note:** `TestData` is automatically run during `deploy:protocol` for testnet networks. It should not be run manually as it's included in the deployment process.

## Monitoring Cross-Chain Messages

- **Axelar**: https://testnet.axelarscan.io
- **Wormhole**: https://wormholescan.io  
- **LayerZero**: https://testnet.layerzeroscan.com
# Cross-Chain scripts
**Note:** Intended for testnet use only.
For bidirectional communication, run the script on each network separately.

## Scripts

### TestData.s.sol
Standalone, local/testnet deployment and validation script for a single chain.

**Purpose:**
- Deploys a pool and both async/sync vaults on a single network (for local dev or isolated testnet functional/smoke tests)
- Validates full async and sync vault flows in one shot on one chain (no messaging/bridging)
- Recommended as a baseline/test sanity check before running cross-chain flows

**Usage:**
```bash
export NETWORK=sepolia
export PROTOCOL_ADMIN=0x... # your EOA
forge script script/testnet/TestData.s.sol:TestData \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

---

### WireAdapters.s.sol
Configures the source network's adapters to communicate with destination networks.

**Purpose:**
- Sets up one-directional communication (source → destination)
- Wires adapters (Wormhole, LayerZero, Axelar) between networks
- Registers adapters that exist on BOTH source and destination networks
- Prevents InvalidAdapter errors from asymmetric configurations

**Usage:**
```bash
export NETWORK=sepolia
forge script script/testnet/WireAdapters.s.sol:WireAdapters \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

---

### TestCrossChainHub.s.sol
Hub-side script to create cross-chain test pools.

**Purpose:**
- Creates pools on the HUB chain for each connected spoke chain
- Sends cross-chain messages to deploy vaults on spoke chains
- Supports multiple test runs with different pool indices

**Prerequisites:**
- Run `deploy.py dump` for the hub network to set environment variables
- Ensure `PROTOCOL_ADMIN` is set

**Configuration (optional env vars):**
- `POOL_INDEX_OFFSET` - Offset to add to pool indices (default: current timestamp % 1000)
- `TEST_RUN_ID` - Custom identifier for this test run (used in pool metadata)

**Usage:**
```bash
cd script/deploy && python deploy.py dump sepolia && cd ../..
source env/latest/11155111-latest.json

# First run (uses timestamp-based offset)
forge script script/testnet/TestCrossChainHub.s.sol:TestCrossChainHub \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv

# Subsequent runs with custom offset
export POOL_INDEX_OFFSET=500
export TEST_RUN_ID="adapter-test-1"
forge script script/testnet/TestCrossChainHub.s.sol:TestCrossChainHub \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

---

### TestCrossChainSpoke.s.sol
Spoke-side script to interact with cross-chain vaults.

**Purpose:**
- Runs on a SPOKE chain to interact with vaults deployed via cross-chain messages from the hub
- Verifies that pools and vaults exist on the spoke chain
- Performs test operations on async and sync vaults

**Prerequisites:**
- `TestCrossChainHub` has been run on the hub chain
- Cross-chain messages have been relayed and processed
- Set `HUB_CENTRIFUGE_ID` and `POOL_INDEX_OFFSET` environment variables

**Configuration (env vars):**
- `HUB_CENTRIFUGE_ID` - The centrifugeId of the hub chain (required)
- `POOL_INDEX_OFFSET` - Must match the offset used in TestCrossChainHub (default: 0)
- `TEST_RUN_ID` - The test run identifier (optional, for logging)

**Usage:**
```bash
cd script/deploy && python deploy.py dump base-sepolia && cd ../..
source env/latest/84532-latest.json
export HUB_CENTRIFUGE_ID=1
export POOL_INDEX_OFFSET=123  # Must match hub script
export TEST_RUN_ID="adapter-test-1"  # Optional
forge script script/testnet/TestCrossChainSpoke.s.sol:TestCrossChainSpoke \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

## Cross-Chain Testing Workflow

1. **Wire Adapters** (on each network):
   ```bash
   # On hub network
   forge script script/testnet/WireAdapters.s.sol:WireAdapters --rpc-url $HUB_RPC_URL --broadcast

   # On each spoke network
   forge script script/testnet/WireAdapters.s.sol:WireAdapters --rpc-url $SPOKE_RPC_URL --broadcast
   ```

2. **Create Test Pools** (on hub network):
   ```bash
   export POOL_INDEX_OFFSET=100
   export TEST_RUN_ID="test-1"
   forge script script/testnet/TestCrossChainHub.s.sol:TestCrossChainHub --rpc-url $HUB_RPC_URL --broadcast
   ```

3. **Wait for Message Relay** (10-20 minutes):
   - Monitor Axelar: https://testnet.axelarscan.io
   - Monitor Wormhole: https://wormholescan.io
   - Monitor LayerZero: https://testnet.layerzeroscan.com

4. **Test on Spoke Chains**:
   ```bash
   export HUB_CENTRIFUGE_ID=1
   export POOL_INDEX_OFFSET=100  # Must match hub
   export TEST_RUN_ID="test-1"   # Must match hub
   forge script script/testnet/TestCrossChainSpoke.s.sol:TestCrossChainSpoke --rpc-url $SPOKE_RPC_URL --broadcast
   ```

## Additional Documentation

See [CROSSCHAIN_TESTING.md](./CROSSCHAIN_TESTING.md) for more detailed testing instructions and scenarios.

