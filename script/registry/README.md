# Registry Documentation

This folder contains everything for Centrifuge's contract registry: scripts that generate and pin registries, CI pipelines that keep them up to date, and the JSON schema they follow.

## Delta Registry Format

Registries use a **delta format**: each version only contains contracts that changed since the previous version. Each delta has a `previousRegistry` field with an IPFS hash to the prior version, forming a linked chain. This enables selective loading, version-aware indexing (each delta has a `startBlock`), and full reconstruction by walking the IPFS chain.

### What "changed since" is measured against

A delta is computed against the **accumulated state of the entire published chain**, not against the tip document. `abi-registry.js` walks `previousRegistry.ipfsHash` from the live tip back to the base snapshot (`utils/registry-chain.js`) and merges every layer, newest winning, to reconstruct the effective state an indexer holds. Only then does it compare `env/*.json` against it.

This matters because each published layer carries *only* its own changes. Comparing against the tip alone marks every contract the tip happens not to carry as new, so a small deploy emits a near-full snapshot — and since the next run then compares against that large layer, successive publishes oscillate between complementary halves of the contract set. The same flaw hides deprecations: a contract dropped from env is only tombstoned if it appears in the layer being compared against.

If the chain cannot be fully reconstructed (broken `previousRegistry.ipfsHash`, unreachable IPFS layer, cycle, or more layers than `REGISTRY_CHAIN_MAX_DEPTH`), generation **fails** rather than emitting an inflated delta. Set `ALLOW_PARTIAL_REGISTRY_CHAIN=1` to override — but expect already-published contracts to be re-emitted and deprecations to be missed. `SOURCE_IPFS=<cid>` starts the walk from that CID instead of the live tip.

If the tip itself cannot be read at all — the live endpoint and its dnslink fallback both unreachable, or an unfetchable `SOURCE_IPFS` — generation fails too, with **no override**. There would be no published state to measure against, so every contract would be re-emitted as new *and* the result would carry `previousRegistry: null`, presenting an outage as a base registry. Publishing a base snapshot on purpose is what `REGISTRY_MODE=full` is for.

Every layer must also declare the network being generated. Nothing in the chain format ties a layer to an environment, so a `SOURCE_IPFS` pointing at the other environment's CID would otherwise flatten *its* contracts into this delta and pass every downstream check — the [delta invariants](#delta-invariants) included, since they compare against that same accumulated state. A mismatch is **not** overridable by `ALLOW_PARTIAL_REGISTRY_CHAIN`: unlike an unreachable gateway it is never something to proceed through. A layer carrying no `network` field at all is treated as unknown rather than wrong, so an old base snapshot that predates the field cannot fail a run.

The walk costs one IPFS fetch per layer, so it grows with publish history: mainnet is ~7 layers, testnet ~50. Layers are fetched from Centrifuge's dedicated Pinata gateway with the shared Pinata gateway, `ipfs.io`, and `dweb.link` as fallbacks, so one flaky gateway cannot fail the run — and every fetched layer is cached by CID (see [Layer cache](#layer-cache)), so steady state is one fetch per new layer.

`node script/registry/walk-registry-chain.js <env>` prints the same walk as a per-layer table when you want to inspect the chain by hand.

### Output modes

`abi-registry.js` can emit a registry in three shapes; the indexer (`api-v3/scripts/fetch-registry.mjs`) reconciles them when it walks the chain.

| Mode | `version` | `previousRegistry` | When |
|------|-----------|--------------------|------|
| `delta` | new resolved version (e.g. `v3.2.0`) | live tip | Default when local-resolved version is strictly newer than the live tip. |
| `patch` | **`null`** | live tip | When the local-resolved version equals the live tip's version. The indexer's `mergeNullVersionPatchesIntoPredecessors` folds the patch into its predecessor — effectively "replacing the last registry" without orphaning anything on IPFS. Use cases: multi-PR contributions to the same protocol version, post-deploy fixup of a missed contract. |
| `full` | new resolved version | `null` | Base / bootstrap snapshot. Same as `--full`. |

Selection:
- **Auto (default)**: `patch` when local version equals live; `delta` otherwise.
- **`REGISTRY_MODE=delta`**: force a normal append even when versions match (escape hatch).
- **`REGISTRY_MODE=patch`**: force a null-version patch (errors out if there is no live to patch onto).
- **`REGISTRY_MODE=full`** or **`--full`**: force a full snapshot.

The chosen mode is logged by `abi-registry.js`, recorded in `<registry>.validation.json` (`summary.mode`), and surfaced in the **Registry Preview** PR comment.

## Endpoints and outputs

- **Published:** `registry.centrifuge.io` (mainnet), `registry.testnet.centrifuge.io` (testnet). Each serves a JSON file with the schema below.
- **Generated files:** `registry-mainnet.json`, `registry-testnet.json` (production and testnet deployments).

---

## How it works

### Scripts

| Script | Purpose |
|--------|---------|
| `abi-registry.js` | Builds `registry-*.json` from env files, explorer APIs, and per-tag Forge ABI caches. Output mode is one of `delta` (append), `patch` (null-version layer that "replaces the last registry" via the indexer's merge logic), or `full` (base snapshot). See [Output modes](#output-modes). |
| `utils/abi-cache.js` | Per-tag Forge ABI cache (worktrees + `forge build`); env key → artifact names (`ABI_NAME_ALIASES` / `resolveArtifactName` / `artifactNamesForContractKey`). See [ABI cache layout](#abi-cache-layout-repo-root). |
| `build-abi-cache.js` | CLI to warm the cache: `node script/registry/build-abi-cache.js <git-tag> [...]` (from repo root). |
| `utils/registry-chain.js` | Walks `previousRegistry.ipfsHash` from a tip document back to the base snapshot (cycle/depth guards) and flattens the layers into the accumulated published state that delta comparison runs against (`flattenRegistryChain`) plus its ABI coverage (`flattenRegistryAbis`). |
| `utils/registry-fetch.js` | All published-registry network I/O in one place: live endpoints, dnslink CID resolution, CID validation, multi-gateway IPFS fetch, and the [layer cache](#layer-cache). |
| `utils/registry-delta.js` | Decides delta membership against the accumulated state: `hasContractChanged`, `computeChainDelta` (changed contracts + deprecation tombstones + [ABI-gap heals](#abi-gaps-and-how-they-heal)). |
| `utils/registry-invariants.js` | `checkDeltaInvariants` — semantic checks that a delta is actually a delta, and that every live contract's ABI exists somewhere in the chain (see [Delta invariants](#delta-invariants)); `loadEnvChains`. |
| `walk-registry-chain.js` | Ops CLI: per-layer audit of the published chain. See [Auditing the published chain](#auditing-the-published-chain). |
| `utils/tag-resolution.js` | Shared helpers: map env contract `version` → git tag (used by `abi-registry.js` and CI). |
| `utils/validate-env-contract-version-tags.js` | CI pre-check: every mainnet/testnet contract must have `version` and a matching local git tag (run after `git fetch --tags`). |
| `validate-env-schema.js` | Validates all `env/*.json` against the expected schema, including every `deploymentInfo.*.startBlock` vs contract `blockNumber` gap (chain-level indexer listeners; catches an L1 block recorded on an L2 chain). Fast-fail gate before generation. |
| `validate-registry.js` | Validates generated registry JSON against indexer hard requirements plus the [delta invariants](#delta-invariants). Sidecar `.validation.json` for PR comments. Uses the same artifact naming as `packAbis` via `utils/abi-cache.js`. |
| `pin-to-ipfs.js` | Pins generated registries to Pinata, outputs CID metadata. |
| `validate-api-keys.js` | Read-only validation of Pinata and Cloudflare credentials. |
| `.github/ci-scripts/detect-changed-environments.js` | Detects mainnet/testnet env changes to skip unnecessary CI builds. |
| `.github/ci-scripts/detect-deployment-commit.js` | Returns the git commit recorded in env `deploymentInfo` (used as `DEPLOYMENT_COMMIT` / `registry.deploymentInfo.gitCommit`, not for per-contract ABI tags). |
| `.github/ci-scripts/compute-env-tags.js` | Creates tags (`deploy-${version}-${timestamp}`) when env files change so deployment commits stay reachable after squashing. |

### CI Pipeline

The `registry.yml` workflow runs on changes under `env/**`, `script/registry/**`, `.github/ci-scripts/**`, or the workflow file. It fetches git tags, validates env contract versions, runs `abi-registry.js` (per-tag ABI caches via worktrees), validates output, and on pull requests posts a **Registry Preview** comment. Pushes to `main` also pin to IPFS and update Cloudflare DNS.

```
pull_request  → validate env + versions → generate registry → validate output → post PR comment
push to main  → same generate/validate path → pin to IPFS → update Cloudflare DNS
workflow_dispatch → manual run (same pipeline)
```

**Pipeline flow:**

```mermaid
flowchart TD
    subgraph pr [Pull Request]
        A[paths match] --> B[Validate env schema + version tags]
        B -->|fail| X1[PR blocked]
        B -->|pass| C[Detect changed environments]
        C --> D[Generate registry]
        D --> E[Validate registry output]
        E -->|errors| X2[PR blocked]
        E -->|pass/warnings| F[Post PR comment with preview + findings]
    end
    subgraph push [Push to main]
        G[merge] --> H[Same pipeline]
        H --> I[Pin to IPFS]
        I --> J[Update Cloudflare]
    end
```

**Validation layers:**

1. **`npm test`** (pre-generation) — unit tests for the chain walk, layer cache, delta membership, and delta invariants. No network access.
2. **`validate-env-schema.js`** (pre-generation) — broken JSON, missing `network.chainId`, invalid addresses, structural renames, and **`deploymentInfo.*.startBlock` vs contract `blockNumber` gap**. Fails the workflow immediately.
3. **`validate-env-contract-version-tags.js`** — every mainnet/testnet contract has a `version` that resolves to a local git tag (ABI cache). Requires `git fetch --tags` in CI.
4. **`validate-registry.js`** (post-generation) — indexer hard requirements on the generated JSON, plus the [delta invariants](#delta-invariants); writes `.validation.json` for the PR comment.

### Delta invariants

Structural validity is not enough: a delta that re-states contracts already published is well-formed JSON, which is how a near-full snapshot shipped as a delta three times. `validate-registry.js` therefore also checks what the delta *means*, against the flattened published chain (skipped for `full` mode and under `SKIP_LIVE_REGISTRY_CHECK=1`):

| Invariant | Severity | Catches |
|-----------|----------|---------|
| **Projection** — applying the delta to the published state reproduces `env/*.json` exactly | error | An omitted change, an invented address, a `blockNumber` that disagrees with env, or a contract dropped from env without a tombstone |
| **Minimality** — no delta entry restates the published address + blockNumber | error | A delta inflated toward a snapshot; re-tombstoning an already-retired contract |
| **ABI coverage** — every live contract resolves to an ABI in the chain, or in this delta | error | A contract an indexer cannot decode, because no layer ever carried its ABI |
| **Size** — delta carries >30% of published contracts | warning | The symptom a human notices first; expected for a broad redeploy or a tombstone backlog |

Stats land in `summary.delta` of the sidecar and in the **Delta size** row of the PR comment. If the chain cannot be reconstructed the invariants warn and skip — generation already fails hard in that case.

### ABI gaps and how they heal

`packAbis` can finish with `⚠ ABIs not found for: …` and still publish, leaving a contract in the chain with no ABI. While deltas were computed against the tip alone, that healed by accident: nearly every contract counted as changed on every run, so its ABI was re-shipped. Comparing against the accumulated state removed the accident, which would otherwise make such a gap **permanent** — nothing re-emits an unchanged contract.

Two mechanisms replace the accident:

1. **Healing.** `computeChainDelta` treats "active in env, but the chain carries none of its required ABI names" as a reason to include a contract, even when its address has not moved. The log marks these `⟲ <name>: unchanged, re-emitted to ship an ABI the chain never carried`, and they are counted separately in the summary.
2. **Detection.** The ABI-coverage invariant errors if a live contract still resolves to no ABI after the delta is applied — so a gap that cannot heal (a misnamed artifact, say) fails the build instead of shipping.

Healing deliberately restates an unchanged contract, which the minimality invariant would otherwise reject; that case downgrades to a warning naming the ABI being shipped. Retired contracts (`address: null`) need no ABI and are exempt.

**Required ABI names** per contract key come from `artifactNamesForContractKey` in `utils/abi-cache.js` — the same mapping `packAbis` uses, including the factory-plus-product rule (`tokenFactory` → `TokenFactory` + `ShareToken`).

**Other workflows:**
- **`tag-env-updates.yml`** – On any push that touches `env/**/*.json`: runs `compute-env-tags.js` and pushes annotated tags.

---

## ABI cache layout (repo root)

All paths are relative to the **protocol repository root** (`process.cwd()` when you run the scripts). The cache is **gitignored** (`/cache/` in `.gitignore`).

```
cache/abi-registry/                    # getAbiCacheRoot() — stable cache
  <git-tag>/                           # Resolved tag string, e.g. v3.1.0 or v3
    out/                               # Full Forge output tree (copied after build)
      <source-dir>/                    # Mirrors forge artifact paths, e.g. src/core/hub/Hub.sol/
        <ContractName>.json            # Standard Foundry JSON artifact; use .abi for the ABI array
      ...
  worktrees/                           # Only exists briefly while a tag is being built
    <git-tag>/                         # git worktree at that ref; submodule init + forge build here
```

**Lifecycle**

1. **`ensureAbiCache(tag)`** (in `utils/abi-cache.js`): if `cache/abi-registry/<tag>/out/` already exists → no-op (cache hit).
2. Otherwise: create `worktrees/<tag>/` via `git worktree add`, `git submodule update --init --recursive`, `forge build --skip test`, copy `worktrees/<tag>/out/` → `<tag>/out/`, then remove the worktree directory.

**Reading ABIs programmatically**

- Per-tag output directory: **`cache/abi-registry/<tag>/out/`** (same shape as a normal `out/` after `forge build`).
- Contract JSON basename usually matches the Solidity contract name (e.g. `Hub.json`). Env/registry keys that differ from artifact names use **`ABI_NAME_ALIASES`** → **`resolveArtifactName()`** → **`artifactNamesForContractKey()`** in `utils/abi-cache.js` (single table; `validate-registry.js` and `packAbis` share it). Example: `fullRestrictionsHook` → `FullRestrictions`.
- **`findAbiInOutput(outDir, artifactName)`** scans immediate subdirs of `out/` (skips `*.t.sol`), loads `<artifactName>.json`, returns `parsed.abi`.

**Warm cache without generating a registry**

```bash
node script/registry/build-abi-cache.js v3.1.0 v3
```

---

## Generating registries locally

**ABIs are built per contract version tag.** Each contract in `env/*.json` has a `version` field (e.g. `"3"`, `"v3.1"`). The script resolves each version to a git tag, builds ABIs from that tag using a worktree, and caches the `out/` artifacts in `cache/abi-registry/<tag>/out/` as described [above](#abi-cache-layout-repo-root). This ensures mixed-version deployments get the correct ABI for every contract. **Every contract version must have a corresponding git tag** or the build will fail.

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

**Patch (replace last registry)** – when local-resolved version equals the live tip, auto-mode picks
this automatically. To force it (e.g. you know you're patching but want to be explicit):

```bash
REGISTRY_MODE=patch \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js testnet
```

The published JSON has `version: null` and points at the live as `previousRegistry`; `api-v3` merges it into the live on read so the indexer sees a single collapsed version. Useful for: multi-PR additions to the same protocol version, hotfix of a missed contract, recovering from a misconfigured publish without breaking the linked list.

**Force delta even when versions match** – escape hatch if you intentionally want a same-version chain entry instead of a patch:

```bash
REGISTRY_MODE=delta \
ETHERSCAN_API_KEY=<key> \
node script/registry/abi-registry.js testnet
```

**Delta with custom previous registry** – fix a broken delta or test against a specific version:

```bash
ETHERSCAN_API_KEY=<key> \
SOURCE_IPFS=<previous-cid> \
node script/registry/abi-registry.js testnet
```

**Finding the `SOURCE_IPFS` value**

In normal delta mode you don't need it — the script resolves the current live CID automatically via the `_dnslink` TXT record on the registry hostname. `SOURCE_IPFS` is only needed when you want to compare against a **specific** older version (e.g. to regenerate a broken delta or test against a pinned CID).

The three ways to find it:

```bash
# 1. DNS dnslink — what the live endpoint currently points to (same as the script uses internally)
dig TXT _dnslink.registry.centrifuge.io +short          # mainnet
dig TXT _dnslink.registry.testnet.centrifuge.io +short  # testnet
# Returns: "dnslink=/ipfs/<CID>" → use the <CID> part

# 2. Live registry JSON — the CID of the *previous* version in the linked chain
curl -s https://registry.centrifuge.io | jq '.previousRegistry.ipfsHash'

# 3. Walk the chain — to go further back, follow .previousRegistry.ipfsHash recursively
curl -s https://ipfs.centrifuge.io/ipfs/<CID> | jq '.previousRegistry.ipfsHash'
```

**Env / flags:** `DEPLOYMENT_COMMIT` (metadata only), `ETHERSCAN_API_KEY` (required), `REGISTRY_MODE=full`, `SOURCE_IPFS`, `ALLOW_PARTIAL_REGISTRY_CHAIN=1` (proceed even if the chain walk is incomplete), `REGISTRY_CHAIN_MAX_DEPTH` (fetch bound for the chain walk, default 500 — see [What "changed since" is measured against](#what-changed-since-is-measured-against)), `REGISTRY_CHAIN_CACHE_DIR` / `REGISTRY_CHAIN_NO_CACHE=1` (see [Layer cache](#layer-cache)); `--full`. For pinning: `PINATA_JWT` (1Password, limited access).

### Auditing the published chain

```bash
node script/registry/walk-registry-chain.js mainnet            # per-layer table
node script/registry/walk-registry-chain.js testnet --depth 100
node script/registry/walk-registry-chain.js --cid <cid>         # start from a specific layer
node script/registry/walk-registry-chain.js mainnet --json      # machine-readable
```

Prints one row per layer with the contracts and tombstones it carries, flags layers holding more than half the accumulated state (`⚠ snapshot-sized`), and exits non-zero if the chain does not walk cleanly to its base snapshot. A healthy chain is small layers on top of a large base snapshot; repeated snapshot-sized layers mean a publish compared against the wrong baseline.

### Layer cache

Published layers are content-addressed, so a CID's contents can never change. Fetched layers are cached at `cache/registry-chain/<cid>.json` (gitignored) and restored in CI via `actions/cache`, which keeps a chain walk to one fetch per new layer instead of re-reading the whole history from rate-limited public gateways on every run. Set `REGISTRY_CHAIN_CACHE_DIR` to relocate it, or `REGISTRY_CHAIN_NO_CACHE=1` to bypass it.

### Validating env files and registries locally

```bash
# Validate all env/*.json files against expected schema
node script/registry/validate-env-schema.js

# Validate a generated registry against indexer hard requirements + delta invariants
node script/registry/validate-registry.js registry/registry-mainnet.json
node script/registry/validate-registry.js registry/registry-testnet.json

# Skip live registry fetch (offline mode; also skips the delta invariants)
SKIP_LIVE_REGISTRY_CHECK=1 node script/registry/validate-registry.js registry/registry-mainnet.json
```

### Running the script tests

```bash
cd script/registry && npm install && npm test
```

`node:test`, no extra dependencies, no network access. Covers the chain walk and flatten, the layer cache, delta membership, and the delta invariants — including a regression fixture that reproduces the tip-only comparison the invariants exist to catch. CI runs this before generating anything.

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

**Deprecated contracts:** When a contract exists anywhere in the accumulated published state — and has not already been tombstoned by a later layer — but was removed from `env/*.json` (rename, merge, or retirement), the delta includes that key with `address: null`. No ABI is shipped for that entry in the delta (the prior registry already carried it). Downstream indexers (e.g. [api-v3](https://github.com/centrifuge/api-v3)) must treat `null` as “stop indexing this logical contract from this version’s deployment boundary”; concrete wiring is left to those projects.

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
          "txHash": "0xcd4e039f241549031a78668d74cc76c4cbd7398c2686c42969a69be73c963976"
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

**How this is produced:** In delta mode, `abi-registry.js` compares local `env/*.json` to the accumulated state of the published chain (walked back from the live endpoint, or from `SOURCE_IPFS=<cid>`). Any contract name present anywhere in that accumulated state but **missing** from the current env for that chain is emitted as above with all-null fields, unless a later layer already tombstoned it. Regenerating against the v3.0 IPFS pin while env reflects v3.1 yields real rows such as `guardian`, `hubHelpers`, `routerEscrow`, and `globalEscrow` on affected chains.

---

## Schema

```typescript
interface Registry {
  network: "mainnet" | "testnet";
  // String for `delta` and `full` modes (e.g. "v3.1.0").
  // null in `patch` mode — api-v3 merges null-version layers into their predecessor.
  // Omitted only when generation could not resolve any version (treated as an error by validate-registry).
  version: string | null;
  deploymentInfo: {
    gitCommit: string;          // Git commit hash used to build the ABIs
  };
  previousRegistry: {           // null for `full` (base) registries
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
    };
  };
  deployment: {
    deployedAt: number | null;     // Unix timestamp (seconds) when the last deployment finished
    startBlock: number | null;     // Block before deployment started (for indexing)
  };
}
```

### Indexer hard requirements (`validate-registry.js`)

These rules apply to **active** contracts (`address` is a non-null string). **Deprecated** delta entries (`address: null`) skip address/blockNumber/ABI checks — they signal retirement; the prior registry already carried the ABI.

| Field | Rule |
|-------|------|
| `version` | Non-empty string for `delta` and `full` registries. **Must be `null`** for `patch` registries (and only when `previousRegistry.ipfsHash` is set, since the indexer merges the patch into its predecessor). |
| `previousRegistry.ipfsHash` | Non-null when a live registry exists for that network (linked list); omit only for the first/base registry. |
| `chains.<chainId>.deployment.startBlock` | Must be a number. Source: `env/*.json` → `deploymentInfo.*.startBlock`. **Gap rule** vs contract `blockNumber` values: enforced in **`validate-env-schema.js`** before generation (chain-level listeners / snapshots). |
| `chains.<chainId>.contracts.<name>.address` | Non-empty string for **active** contracts; `null` only for deprecations. |
| `chains.<chainId>.contracts.<name>.blockNumber` | Must be a number for active contracts. |
| `abis.<ArtifactName>` | Must exist for every **active** contract in `chains` (and factory implementation ABIs where applicable). Artifact basenames = `artifactNamesForContractKey()` / `resolveArtifactName()` in `utils/abi-cache.js` — same as `packAbis` (e.g. `fullRestrictionsHook` → `FullRestrictions`). |

**Other / soft fields:** `txHash`, `deployment.deployedAt`, `deploymentInfo.gitCommit`, `previousRegistry.version`, and `adapters` are not hard-gated the same way; see validator output for warnings.

**Deprecated contracts:** `address`, `blockNumber`, and `txHash` may be `null`; no ABI is required in the delta for that key (see [example](#example-delta-json-with-deprecated-contracts)).
