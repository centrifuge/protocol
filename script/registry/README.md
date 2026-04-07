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

**ABIs are built per contract version tag.** Each contract in `env/*.json` has a `version` field (e.g. `"3"`, `"v3.1"`). The script resolves each version to a git tag, builds ABIs from that tag using a worktree, and caches the `out/` artifacts in `cache/abi-registry/<tag>/out/`. This ensures mixed-version deployments get the correct ABI for every contract. **Every contract version must have a corresponding git tag** or the build will fail.

**No manual `forge build` step is required.** The script handles it automatically per tag. Cached builds are reused on subsequent runs; delete `cache/abi-registry/` to force a full rebuild.

**Delta (default)** – only contracts that changed since the previous version:

```bash
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js mainnet

# testnet
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js testnet
```

**Full snapshot** – all contracts, no delta; use for base registry or first version in a new format:

```bash
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js mainnet --full
```

**Delta with custom previous registry** – fix a broken delta or test against a specific version:

```bash
ETHERSCAN_API_KEY=<key> \
SOURCE_IPFS=<previous-cid> \
node script/registry/abi-registry.js testnet
```

**Env / flags:** `DEPLOYMENT_COMMIT` (metadata only), `ETHERSCAN_API_KEY` (required), `REGISTRY_MODE=full`, `SOURCE_IPFS`; `--full`, `--source-url=<url>`. For pinning: `PINATA_JWT` (1Password, limited access).

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

**Deprecated contracts:** When a contract existed in the previous registry but was removed from `env/*.json` (rename, merge, or retirement), the delta includes that key with `address: null`. No ABI is shipped for that entry in the delta (the prior registry already carried it). Downstream indexers (e.g. [api-v3](https://github.com/centrifuge/api-v3)) must treat `null` as “stop indexing this logical contract from this version’s deployment boundary”; concrete wiring is left to those projects.

---

## Example: delta JSON with deprecated contracts

Below is a **trimmed** illustration of what a delta looks like when some v3.0 contracts were removed or renamed in v3.1. Only chains that have changes appear under `chains`. Deprecated entries sit next to normal ones; `abis` only lists contracts that need new or updated ABIs in this delta (not the deprecated keys).

```json
{
  "network": "mainnet",
  "version": "v3.1",
  "deploymentInfo": {
    "gitCommit": "c89c55ff6"
  },
  "previousRegistry": {
    "version": "3",
    "ipfsHash": "bafybeief457bljpdmydiyizgyck6bwf2a5y2rfnlhxsqzxosdlaecokogu"
  },
  "abis": {
    "Hub": [ "..." ],
    "Spoke": [ "..." ]
  },
  "chains": {
    "1": {
      "network": {
        "chainId": 1,
        "centrifugeId": 0
      },
      "adapters": {},
      "contracts": {
        "guardian": {
          "address": null,
          "blockNumber": null,
          "txHash": null
        },
        "globalEscrow": {
          "address": null,
          "blockNumber": null,
          "txHash": null
        },
        "hub": {
          "address": "0xA4A7Bb3831958463b3FE3E27A6a160F764341953",
          "blockNumber": 24319335,
          "txHash": "0xcd4e039f241549031a78668d74cc76c4cbd7398c2686c42969a69be73c963976",
          "version": "v3.1"
        }
      },
      "deployment": {
        "deployedAt": 1737893250,
        "startBlock": 24319298
      }
    }
  }
}
```

**How this is produced:** In delta mode, `abi-registry.js` compares local `env/*.json` to the previous registry (live endpoint or `SOURCE_IPFS=<cid>`). Any contract name present in the previous registry’s chain but **missing** from the current env for that chain is emitted as above with all-null fields. Regenerating against the v3.0 IPFS pin while env reflects v3.1 yields real rows such as `guardian`, `hubHelpers`, `routerEscrow`, and `globalEscrow` on affected chains.

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
    protocolAdmin?: string;     // multisig safe admin address
    opsAdmin?: string;          // multisig safe admin address
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
      address: string | null;      // null = contract deprecated in this version
      blockNumber: number | null;  // Block number at contract creation
      txHash: string | null;       // Transaction hash of contract deployment
      version?: string;            // From env; omitted for deprecated entries
    };
  };
  deployment: {
    deployedAt: number | null;     // Unix timestamp (seconds) when the last deployment finished
    startBlock: number | null;     // Block before deployment started (for indexing)
  };
}
```

### Nullable fields

- **`contracts[name].address`** – `null` when the contract was deprecated (removed from env files in this version). Consumers should stop indexing at this version's deployment block.
- **`contracts[name].blockNumber` / `txHash`** – Filled from broadcast artifacts or explorer APIs. Can be `null` when contract is unverified, chain isn’t on the free Etherscan API (e.g. BNB, Base), or legacy env has no `txHash`.
- **`deployment.deployedAt`** – `null` if env has no `deploymentInfo.timestamp`.
- **`deployment.startBlock`** – `null` if env has no `deploymentInfo.startBlock` (expected for future deployments).
- **`adapters.$adapterName`** – `null` when that adapter isn’t configured for the network.
