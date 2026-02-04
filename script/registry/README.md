# Registry Documentation

This folder contains everything for Centrifuge's contract registry: scripts that generate and pin registries, CI pipelines that keep them up to date, and the JSON schema they follow.

## Delta Registry Format

Registries use a **delta format**: each version only contains contracts that changed since the previous version. Each delta has a `previousRegistry` field with an IPFS hash to the prior version, forming a linked chain. This enables selective loading, version-aware indexing (each delta has a `startBlock`), and full reconstruction by walking the IPFS chain.

## Endpoints and outputs

- **Published:** `registry.centrifuge.io` (mainnet), `registry.testnet.centrifuge.io` (testnet). Each serves a JSON file with the schema below.
- **Generated files:** `registry-mainnet.json`, `registry-testnet.json` (production and testnet deployments).

---

## How it works

### Scripts

| Script | Purpose |
|--------|---------|
| `abi-registry.js` | Builds `registry-*.json` from env files, explorer APIs, and Forge broadcast artifacts. Supports delta (default) or full snapshot. |
| `pin-to-ipfs.js` | Pins generated registries to Pinata, writes nightly/mainnet/testnet summaries, outputs CID metadata. |
| `.github/ci-scripts/detect-changed-environments.js` | Detects mainnet/testnet env changes to skip unnecessary CI builds. |
| `.github/ci-scripts/detect-deployment-commit.js` | Returns the git commit that produced the latest env files so ABIs are built from that revision. |
| `.github/ci-scripts/compute-env-tags.js` | Creates tags (`deploy-${version}-${timestamp}`) when env files change so deployment commits stay reachable after squashing. |

### Pipelines

- **`registry.yml`** – On env/registry changes: detects changed envs, rebuilds ABIs at deployment commits, generates `registry-mainnet.json` / `registry-testnet.json`, publishes artifacts, pins to IPFS, writes step summaries with CIDs and opens issues when pointers need updates.
- **`tag-env-updates.yml`** – On any push that touches `env/**/*.json`: runs `compute-env-tags.js` and pushes annotated tags.

---

## Generating registries locally

**Build ABIs from the deployment commit.** The `/out` folder must come from that commit, not from the branch tip.

```bash
git checkout <deployment-commit>
# or: git worktree add /tmp/deploy-build <deployment-commit> && cd /tmp/deploy-build
forge build --skip test
# if worktree: cp -R /tmp/deploy-build/out ./out and cd back
```

**Delta (default)** – only contracts that changed since the previous version:

```bash
DEPLOYMENT_COMMIT=$(node .github/ci-scripts/detect-deployment-commit.js mainnet) \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js mainnet

# testnet
DEPLOYMENT_COMMIT=$(node .github/ci-scripts/detect-deployment-commit.js testnet) \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js testnet
```

**Full snapshot** – all contracts, no delta; use for base registry or first version in a new format:

```bash
DEPLOYMENT_COMMIT=$(node .github/ci-scripts/detect-deployment-commit.js mainnet) \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js mainnet --full
```

**Delta with custom previous registry** – fix a broken delta or test against a specific version:

```bash
DEPLOYMENT_COMMIT=<commit> \
ETHERSCAN_API_KEY=<key> \
REGISTRY_SOURCE_URL="https://gateway.pinata.cloud/ipfs/<previous-cid>" \
node script/registry/abi-registry.js testnet
```

**Env / flags:** `DEPLOYMENT_COMMIT`, `ETHERSCAN_API_KEY` (required), `REGISTRY_MODE=full`, `REGISTRY_SOURCE_URL`; `--full`, `--source-url=<url>`. For pinning: `PINATA_JWT` (1Password, limited access).

### Testing API keys (no changes made)

To confirm Pinata and Cloudflare credentials work without modifying DNS or pinning new files:

```bash
cd script/registry && npm install
```

- **Pinata (read):** `PINATA_JWT=<jwt> node validate-api-keys.js` — lists pins (read-only).
- **Cloudflare (read):** `CLOUDFLARE_ZONE_ID=<id> CLOUDFLARE_API_TOKEN=<token> node validate-api-keys.js` — lists Web3 hostnames. Use the **zone** ID (from the zone’s Overview), not the account ID. If you see "Invalid API Token" but the token works in the dashboard, set `CLOUDFLARE_ACCOUNT_ID` to your **account** ID (from the token’s verify URL or dashboard); the script will then use the account-scoped verify endpoint.
- **Cloudflare (prove write, no-op):** same env plus `--test-write` — PATCHes each hostname with its current dnslink so nothing changes, but confirms the token can write.
- **Both:** set all three env vars and run `node validate-api-keys.js` (optionally `--test-write` for Cloudflare).

Use `--pinata-only` or `--cloudflare-only` to test a single provider. If you see "Invalid API Token", ensure the token is active, not expired, and copied in full; create a new token in Cloudflare if needed.

**Equivalent curl commands (Cloudflare):** Use your **account** ID for verify and **zone** ID for hostnames.

```bash
# 1. Token verify (account-scoped token: use account ID in URL)
curl -s "https://api.cloudflare.com/client/v4/accounts/ACCOUNT_ID/tokens/verify" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"

# 2. List Web3 hostnames (use zone ID)
curl -s "https://api.cloudflare.com/client/v4/zones/ZONE_ID/web3/hostnames" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

If (1) works but the script fails at step 1/5, set `CLOUDFLARE_ACCOUNT_ID` to your account ID so the script uses the same verify URL.

---

## Registry consumption

**Selective loading (indexers):** Use the latest delta; swap ABIs only for contracts that changed at the delta’s block.

**Full reconstruction:** Walk `previousRegistry.ipfsHash` backwards from the latest registry URL, then merge `abis` and `chains` (older first, newer overrides).

**Single version:** Import the JSON; use `registry.abis.<ContractName>`, `registry.chains[chainId].contracts.<name>.address`, and optional `blockNumber` / `txHash` for deployment metadata.

---

## Schema

```typescript
interface Registry {
  network: "mainnet" | "testnet";
  version: string;              // Version identifier (e.g., "3.0", "3.1.12")
  deploymentInfo: {
    gitCommit: string;          // Git commit hash used to build the ABIs
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
  };
}
```

### Nullable fields

- **`contracts[name].blockNumber` / `txHash`** – Filled from broadcast artifacts or explorer APIs. Can be `null` when contract is unverified, chain isn’t on the free Etherscan API (e.g. BNB, Base), or legacy env has no `txHash`.
- **`deployment.deployedAt`** – `null` if env has no `deploymentInfo.timestamp`.
- **`deployment.startBlock`** – `null` if env has no `deploymentInfo.startBlock` (expected for future deployments).
- **`adapters.$adapterName`** – `null` when that adapter isn’t configured for the network.
