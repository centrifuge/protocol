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

## Additional Documentation

See [CROSSCHAIN_TESTING.md](./CROSSCHAIN_TESTING.md) for more detailed testing instructions and scenarios.
