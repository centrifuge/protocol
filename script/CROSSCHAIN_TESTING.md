# Cross-Chain Testing Guide

Guide for testing cross-chain operations between Sepolia networks using configurable test scripts.

## Overview

The protocol supports cross-chain operations where:
- **Hub operations** (pool creation, share class management) happen on one chain
- **Vault/BalanceSheet operations** (deposits, withdrawals) can happen on different chains
- When operations target a different `centrifugeId`, cross-chain messages are automatically sent via adapters (Axelar, Wormhole, LayerZero)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    HUB CHAIN (Sepolia)                       │
│                    centrifugeId: 1                           │
│                                                              │
│  TestCrossChainHub.s.sol runs here                          │
│                                                              │
│  1. Creates pools for each connected spoke chain            │
│  2. Registers assets for spoke centrifugeIds                │
│  3. Sends cross-chain messages to deploy vaults             │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           │ Cross-chain Messages
                           │ (Axelar/Wormhole/LayerZero)
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              SPOKE CHAINS (Base/Arbitrum Sepolia)           │
│              centrifugeId: 2 or 3                           │
│                                                              │
│  TestCrossChainSpoke.s.sol runs here                        │
│                                                              │
│  1. Verifies pools and vaults were deployed                 │
│  2. Interacts with vaults (deposit, withdraw, etc.)         │
│  3. Tests vault functionality                               │
└─────────────────────────────────────────────────────────────┘
```

## Scripts Overview

| Script | Purpose | Runs On | Reusable | Description |
|--------|---------|---------|----------|-------------|
| **TestData.s.sol** | Local testing | Any chain | ❌ Once | Single-chain initial setup (run once) |
| **TestCrossChainHub.s.sol** | Hub setup | Hub chain (Sepolia) | ✅ Multiple | Creates pools for testing adapters (configurable) |
| **TestCrossChainSpoke.s.sol** | Spoke testing | Spoke chain (Base/Arbitrum) | ✅ Multiple | Tests vaults on spoke chain (configurable) |

## Test Networks

| Network | Chain ID | centrifugeId | Config File | Connects To |
|---------|----------|--------------|-------------|-------------|
| Sepolia | 11155111 | 1 | `env/sepolia.json` | base-sepolia, arbitrum-sepolia |
| Base Sepolia | 84532 | 2 | `env/base-sepolia.json` | sepolia |
| Arbitrum Sepolia | 421614 | 3 | `env/arbitrum-sepolia.json` | sepolia, base-sepolia |

## Quick Start

### 1. Hub Side (Sepolia)

```bash
# Setup environment
cd script/deploy && python deploy.py dump sepolia && cd ../..
source env/latest/11155111-latest.json

# First run (auto-generates unique pool indices)
forge script script/TestCrossChainHub.s.sol:TestCrossChainHub \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvvv

# Or with custom offset for repeated testing
export POOL_INDEX_OFFSET=500
export TEST_RUN_ID="axelar-test-1"
forge script script/TestCrossChainHub.s.sol:TestCrossChainHub \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvvv
```

**Note:** The script outputs the `POOL_INDEX_OFFSET` and `TEST_RUN_ID` values you need for the spoke script.

### 2. Wait for Messages (2-5 minutes)

Monitor: https://testnet.axelarscan.io

### 3. Spoke Side (Base Sepolia)

```bash
# Setup environment
cd script/deploy && python deploy.py dump base-sepolia && cd ../..
source env/latest/84532-latest.json

# Set values from hub script output
export HUB_CENTRIFUGE_ID=1
export POOL_INDEX_OFFSET=500  # MUST match hub script
export TEST_RUN_ID="axelar-test-1"

# Run spoke script
forge script script/TestCrossChainSpoke.s.sol:TestCrossChainSpoke \
    --rpc-url $RPC_URL \
    --broadcast \
    -vvvv
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `POOL_INDEX_OFFSET` | No | `timestamp % 1000` | Offset for pool indices (allows repeated testing) |
| `TEST_RUN_ID` | No | `timestamp` | Identifier for this test run (used in pool metadata) |
| `HUB_CENTRIFUGE_ID` | **Yes** (spoke only) | - | centrifugeId of the hub chain |

### Pool Index Pattern

Pools use a configurable pattern for reusability:

```
Async pool:  spokeCentrifugeId * 1000 + poolIndexOffset * 2 + 1
Sync pool:   spokeCentrifugeId * 1000 + poolIndexOffset * 2 + 2

Examples (with offset=0):
- Base Sepolia (centrifugeId=2): pools 2001, 2002
- Arbitrum Sepolia (centrifugeId=3): pools 3001, 3002

Examples (with offset=500):
- Base Sepolia (centrifugeId=2): pools 3001, 3002
- Arbitrum Sepolia (centrifugeId=3): pools 4001, 4002
```

## Testing Multiple Adapters

The scripts are designed for **repeated testing** of adapters/bridges:

```bash
# Test Run 1: Axelar
export POOL_INDEX_OFFSET=100
export TEST_RUN_ID="axelar-test"
# Run hub and spoke scripts...

# Test Run 2: Wormhole  
export POOL_INDEX_OFFSET=200
export TEST_RUN_ID="wormhole-test"
# Run hub and spoke scripts...

# Test Run 3: LayerZero
export POOL_INDEX_OFFSET=300
export TEST_RUN_ID="layerzero-test"
# Run hub and spoke scripts...
```

Each run creates **fresh pools** without conflicts.

## Troubleshooting

### Messages not arriving?
- Check relay status on explorer
- Wait longer (can take 10+ minutes)
- Verify adapters configured in network JSON

### Vaults not found?
- Verify messages were received (check logs)
- Ensure pool/share class IDs match
- Check factory contracts deployed on spoke

### Script errors?
- Run `deploy.py dump <network>` first
- Source the generated env file
- Set `HUB_CENTRIFUGE_ID` for spoke script

## Key Concepts

- **centrifugeId determines message routing**: 
  - Same centrifugeId = local processing
  - Different centrifugeId = cross-chain message

- **Pool created on hub, vault deployed on spoke**:
  - Hub manages pool state and accounting
  - Spoke hosts actual vault contracts for user interaction

- **Use deploy.py dump for environment**:
  - Sets all necessary variables (RPC, addresses, etc.)
  - Ensures consistent configuration

## Quick Reference

### Hub Script (Sepolia)
```bash
cd script/deploy && python deploy.py dump sepolia && cd ../..
source env/latest/11155111-latest.json
forge script script/TestCrossChainHub.s.sol:TestCrossChainHub --rpc-url $RPC_URL --broadcast -vvvv
```

### Spoke Script (Base Sepolia)
```bash
cd script/deploy && python deploy.py dump base-sepolia && cd ../..
source env/latest/84532-latest.json
export HUB_CENTRIFUGE_ID=1
export POOL_INDEX_OFFSET=500  # Match hub script
forge script script/TestCrossChainSpoke.s.sol:TestCrossChainSpoke --rpc-url $RPC_URL --broadcast -vvvv
```

### Spoke Script (Arbitrum Sepolia)
```bash
cd script/deploy && python deploy.py dump arbitrum-sepolia && cd ../..
source env/latest/421614-latest.json
export HUB_CENTRIFUGE_ID=1
export POOL_INDEX_OFFSET=500  # Match hub script
forge script script/TestCrossChainSpoke.s.sol:TestCrossChainSpoke --rpc-url $RPC_URL --broadcast -vvvv
```