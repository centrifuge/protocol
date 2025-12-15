# Registry Documentation

This folder contains everything related to Centrifuge's contract registry. It documents the JSON schema, helper scripts, and automated workflows that keep the registries up to date.

## Delta Registry Format

Starting with v3.0, registries use a **delta format** where each version only contains contracts that changed since the previous version. This enables:

- **Selective loading**: Only load the delta you need, swap ABIs for changed contracts
- **Version-aware indexing**: Each delta has a `startBlock` - use different ABIs for different block ranges
- **Full reconstruction**: Walk the IPFS chain to build the complete registry when needed

Each delta registry includes a `previousRegistry` field with an IPFS hash pointer to the prior version, creating a linked chain of versions.

## Published endpoints

- `registry.centrifuge.io` – current production (mainnet) registry for the latest deployed release.
- `registry.testnet.centrifuge.io` – registry for the currently deployed testnet release. This normally matches production unless the next release is being staged.

Each endpoint hosts a JSON file with the schema described below.

## Generated files

- `registry-mainnet.json` – production deployments (Ethereum, Base, Arbitrum, etc.)
- `registry-testnet.json` – testnet deployments (Sepolia, Base Sepolia, Arbitrum Sepolia, etc.)

## Schema

```typescript
interface Registry {
  network: "mainnet" | "testnet";
  version: string;              // Version identifier (e.g., "3.0", "3.1.12")
  deploymentInfo: {
    gitCommit: string;          // Git commit hash used to build the ABIs
    startBlock: number | null;  // Lowest block number across all chains for this deployment
  };
  previousRegistry: {           // null for first/base registry
    version: string;            // Version of the previous registry
    ipfsHash: string;           // IPFS CID to fetch the previous registry
  } | null;
  abis: {
    [contractName: string]: AbiItem[];  // ABIs for contracts that changed in this version
  };
  chains: {
    [chainId: string]: ChainConfig;     // Only chains with changed contracts
  };
}

interface ChainConfig {
  network: {
    chainId: number;
    centrifugeId: number;       // Internal Centrifuge chain identifier
    safeAdmin?: string;         // Safe multisig admin address (mainnet only)
  };
  adapters: {
    wormhole?: {
      wormholeId: string;
      relayer: string;
    };
    axelar?: {
      axelarId: string;
      gateway: string | null;
      gasService: string | null;
    };
    layerZero?: {
      endpoint: string;
      layerZeroEid: number;
    };
  };
  contracts: {
    [contractName: string]: {
      address: string;
      blockNumber: number | null;  // Block number at contract creation
      txHash: string | null;       // Transaction hash of contract deployment
    };
  };
  deployment: {
    deployedAt: number | null;     // Unix timestamp (seconds) when the last deployment finished
    startBlock: number | null;     // Block before deployment started (for indexing)
    endBlock: number | null;       // Block after deployment finished (for indexing)
  };
}
```

## Nullable fields and trade-offs

Several fields may be `null` depending on data availability:

### `contracts[name].blockNumber` and `contracts[name].txHash`

These fields are populated from:

1. **Broadcast artifacts** – when deploying via Forge scripts, `verifier.py` extracts real block numbers and tx hashes from `broadcast/*/run-latest.json`.
2. **Explorer APIs** – as a fallback for block numbers when they are missing from env files.

They may still be `null` when:
- **Contract not verified** – explorer APIs do not return block info if the contract is not verified.
- **Unsupported chains** – BNB Smart Chain (56, 97) and Base (8453, 84532) are not available via the free Etherscan API. Block numbers must be manually added to env files or inferred from `deployment.{start|end}Block`.
- **Custom explorer chains** – Avalanche (43114) and Plume (98866) use alternative APIs (Routescan, Conduit) which may not have data for every contract.
- **Legacy deployments** – older env files might not contain `txHash`.

### `deployment.deployedAt`

May be `null` when the env file is missing `deploymentInfo.timestamp`.

### `deployment.startBlock` / `deployment.endBlock`

May be `null` when the env file lacks `deploymentInfo.startBlock` / `deploymentInfo.endBlock`. We expect this to exist for future deployments.

### `adapters.$adapterName`

May be `null` when an adapter is not configured for a given network.

## Helper scripts

| Script | Description |
| --- | --- |
| `abi-registry.js` | Generates `registry-*.json` using env files, explorer APIs, and Forge broadcast artifacts. |
| `pin-to-ipfs.js` | Pins generated registries to Pinata, writes the nightly/mainnet/testnet summaries, and outputs CID metadata. |
| `.github/ci-scripts/detect-changed-environments.js` | Detects if mainnet or testnet env files changed to skip unnecessary builds. |
| `.github/ci-scripts/detect-deployment-commit.js` | Determines which git commit generated the latest env files so ABIs can be rebuilt for that revision. |
| `.github/ci-scripts/compute-env-tags.js` | Creates git tags (`deploy-${version}-${timestamp}`) whenever env files change to preserve deployment hashes after squashing commits. |

## Generating registries locally

```bash
# Generate mainnet registry
DEPLOYMENT_COMMIT=$(node .github/ci-scripts/detect-deployment-commit.js mainnet) \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js mainnet

# Generate testnet registry
DEPLOYMENT_COMMIT=$(node .github/ci-scripts/detect-deployment-commit.js testnet) \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js testnet
```

Environment variables:
- `DEPLOYMENT_COMMIT` – commit hash to read ABIs from, you can use `.github/ci-scripts/detect-deployment-commit.js` to set it.
- `ETHERSCAN_API_KEY` – required to fetch contract creation data for Etherscan-compatible chains. You can use `script/deploy/deploy.py $any_network_name config:dump` to dump the API key to a .env file
- `PINATA_JWT` – required by `pin-to-ipfs.js` to pin registries. Only available in 1Password (not for everybody)

## CI/CD overview

1. **`registry.yml` workflow**
   - Detects changed env files.
   - Rebuilds ABIs at the relevant deployment commits.
   - Generates `registry-mainnet.json` / `registry-testnet.json`.
   - Publishes artifacts and pins updated registries to IPFS (main, testnet, nightly endpoints).
   - Writes step summaries with CIDs and creates GitHub issues when pointers need updates.

2. **`tag-env-updates.yml` workflow**
   - Runs on any push that modifies `env/**/*.json`.
   - Computes tags using `compute-env-tags.js` and pushes annotated tags so deployment commits remain reachable.

## Registry Consumption

### Option 1: Selective Loading (Recommended for Indexers)

Each delta tells you which contracts changed at which block. Load deltas selectively and swap ABIs only for changed contracts:

```javascript
// Fetch latest delta
const latest = await fetch("https://registry.centrifuge.io").then(r => r.json());

// At block X, use these new ABIs for these contracts
console.log(`Version ${latest.version} starts at block ${latest.deploymentInfo.startBlock}`);
console.log(`Changed contracts:`, Object.keys(latest.chains["1"]?.contracts || {}));

// Keep existing ABIs for unchanged contracts, swap only the new ones
```

### Option 2: Full Registry Reconstruction

Walk the IPFS chain to build a complete registry with all contracts:

```javascript
const IPFS_GATEWAY = "https://gateway.pinata.cloud/ipfs/";

async function buildFullRegistry(startUrl) {
  const versions = [];
  let url = startUrl;
  
  // Walk backwards through the chain
  while (url) {
    const registry = await fetch(url).then(r => r.json());
    versions.unshift(registry); // oldest first
    url = registry.previousRegistry?.ipfsHash 
      ? IPFS_GATEWAY + registry.previousRegistry.ipfsHash 
      : null;
  }
  
  // Merge: older first, newer overrides
  const merged = { chains: {}, abis: {} };
  for (const reg of versions) {
    Object.assign(merged.abis, reg.abis || {});
    for (const [chainId, data] of Object.entries(reg.chains || {})) {
      if (!merged.chains[chainId]) merged.chains[chainId] = { contracts: {} };
      Object.assign(merged.chains[chainId].contracts, data.contracts || {});
    }
  }
  return merged;
}
```

### Simple Example (Single Version)

```javascript
import registry from './registry-mainnet.json';

// ABI for a contract
const vaultRouterAbi = registry.abis.VaultRouter;

// Contract address on Ethereum (chainId 1)
const vaultRouter = registry.chains["1"].contracts.vaultRouter;
const vaultRouterAddress = vaultRouter.address;

// Deployment metadata
const deploymentBlock = vaultRouter.blockNumber;
const deploymentTx = vaultRouter.txHash;
if (deploymentTx) {
  console.log(`View deployment: https://etherscan.io/tx/${deploymentTx}`);
}
```

