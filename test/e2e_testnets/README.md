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
forge script script/crosschain/TestData.s.sol:TestData \
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
forge script script/crosschain/WireAdapters.s.sol:WireAdapters \
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
forge script script/crosschain/TestCrossChainHub.s.sol:TestCrossChainHub \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv

# Subsequent runs with custom offset
export POOL_INDEX_OFFSET=500
export TEST_RUN_ID="adapter-test-1"
forge script script/crosschain/TestCrossChainHub.s.sol:TestCrossChainHub \
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
forge script script/crosschain/TestCrossChainSpoke.s.sol:TestCrossChainSpoke \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvvv
```

## Cross-Chain Testing Workflow

1. **Wire Adapters** (on each network):
   ```bash
   # On hub network
   forge script script/crosschain/WireAdapters.s.sol:WireAdapters --rpc-url $HUB_RPC_URL --broadcast

   # On each spoke network
   forge script script/crosschain/WireAdapters.s.sol:WireAdapters --rpc-url $SPOKE_RPC_URL --broadcast
   ```

2. **Create Test Pools** (on hub network):
   ```bash
   export POOL_INDEX_OFFSET=100
   export TEST_RUN_ID="test-1"
   forge script script/crosschain/TestCrossChainHub.s.sol:TestCrossChainHub --rpc-url $HUB_RPC_URL --broadcast
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
   forge script script/crosschain/TestCrossChainSpoke.s.sol:TestCrossChainSpoke --rpc-url $SPOKE_RPC_URL --broadcast
   ```

## Additional Documentation

See [CROSSCHAIN_TESTING.md](./CROSSCHAIN_TESTING.md) for more detailed testing instructions and scenarios.

