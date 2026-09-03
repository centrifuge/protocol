---
paths:
  - "script/registry/**"
  - "env/**/*.json"
  - ".github/workflows/registry.yml"
  - ".github/ci-scripts/detect-*.js"
  - ".github/ci-scripts/compute-env-tags.js"
---

# Contract registry scripts (`script/registry/`)

**Source of truth for behavior and schema:** [script/registry/README.md](../../script/registry/README.md). Prefer updating that README when behavior or flags change. **ABI cache directory layout** is documented there (“ABI cache layout (repo root)”) for humans and AI tools.

## Layout

| Area | Role |
|------|------|
| `abi-registry.js` | Builds `registry/registry-{mainnet,testnet}.json` from `env/*.json`, explorer APIs, deltas vs the flattened published chain (walked from the live registry or `SOURCE_IPFS`). |
| `utils/registry-chain.js` | Walks `previousRegistry.ipfsHash` to the base snapshot and flattens layers into the accumulated published state. Call `collectRegistryChain` and take its `accumulated` — it flattens for you; `flattenRegistryChain` is exported for tests and requires oldest → newest ordering. |
| `utils/registry-fetch.js` | **All** published-registry network I/O: `REGISTRY_URLS`, `DNSLINK_HOSTNAMES`, `IPFS_GATEWAYS`, `isValidIpfsHash`, `resolveLiveCid`, `fetchRegistryFromIpfs`, `fetchLiveRegistry`, CID layer cache. Never declare these a second time elsewhere. |
| `utils/registry-delta.js` | Delta membership against the accumulated state: `hasContractChanged`, `computeChainDelta`. |
| `utils/registry-invariants.js` | `checkDeltaInvariants` (projection / minimality / size), `loadEnvChains`. |
| `utils/env-dirs.js` | Which `env/` directory each registry publishes: `env/registry.json` (`resolveEnvironmentDir`, `envFilesOf`, `allEnvFiles`). **Never enumerate `env/mainnet`/`env/testnet` by hand** — `env/testnet-<id>/` directories are other deployments of the same chains, and only the pointed one is published. |
| `walk-registry-chain.js` | Ops CLI: per-layer chain audit (contracts + tombstones per layer, flags snapshot-sized layers). |
| `test/` | `node:test` suite, no extra deps: `cd script/registry && npm test`. |
| `utils/abi-cache.js` | Per-tag Forge ABI cache (worktree + build + `out/` copy); `collectContractTags`, `findAbiInOutput`, `resolveArtifactName` / `artifactNamesForContractKey` (single `ABI_NAME_ALIASES` table) — reusable outside the registry script. |
| `build-abi-cache.js` | CLI: `node script/registry/build-abi-cache.js <tag> [...]` to warm `cache/abi-registry/`. |
| `utils/tag-resolution.js` | Maps env contract `version` → local git tag (`resolveVersionTag`, candidates). |
| `utils/validate-env-contract-version-tags.js` | CI: every mainnet/testnet contract object must have `version` resolving to a git tag. |
| `validate-env-schema.js` | CI: structural validation of `env/*.json` before generation. |
| `validate-registry.js` | Post-generation indexer checks; `.validation.json` sidecar for PR comments. Skips ABI/address rules for `address: null` deprecations. |
| `pin-to-ipfs.js`, `validate-api-keys.js`, etc. | Pinning and local API checks; see README table. |

## ABI generation

- **`utils/abi-cache.js`** owns the per-tag cache (`ensureAbiCache`, `collectContractTags`, …); `abi-registry.js` and `build-abi-cache.js` call into it.
- ABIs come from **per-contract `version` in env** → resolved git tag → `cache/abi-registry/<tag>/out/` (worktree + `forge build --skip test`). Not from a single deployment commit’s `out/`.
- **`DEPLOYMENT_COMMIT`** (env) is metadata only (`registry.deploymentInfo.gitCommit`), not ABI selection.
- After `packAbis`, **`stripContractVersionsForRegistryOutput`** removes per-contract `version` from serialized JSON (smaller artifacts); **`version` stays in repo `env/*.json`**.

## Delta mode & deprecations

- **Delta only** (not `--full`): compare each chain to the **accumulated state of the whole published chain** — `collectRegistryChain` + `flattenRegistryChain` from the tip (live URL or `SOURCE_IPFS`) back to the base snapshot, newest layer winning. **Never compare against the tip document alone:** each layer carries only its own changes, so that inflates the delta to a near-full snapshot, makes successive publishes oscillate between complementary halves of the contract set, and hides deprecations.
- **Incomplete chain** (broken pointer, unreachable layer, cycle, depth bound) → **exit non-zero**; `ALLOW_PARTIAL_REGISTRY_CHAIN=1` overrides, `REGISTRY_CHAIN_MAX_DEPTH` raises the fetch bound (default 500; testnet is already ~50 layers).
- **Unreadable tip** (live endpoint + dnslink fallback both down, or unfetchable `SOURCE_IPFS`) → **exit non-zero, no override**: with no baseline every contract reads as new *and* `previousRegistry` stays null, so an outage would pin itself as a base registry. Use `REGISTRY_MODE=full` to publish a base snapshot deliberately.
- **CID hygiene:** `previousRegistry.ipfsHash` comes from published documents, so `fetchRegistryFromIpfs` refuses anything that is not a plain alphanumeric segment before it reaches a gateway URL or the `cache/registry-chain/<cid>.json` path.
- **Wrong-network layer** → `collectRegistryChain` returns `fatal: true` with an empty state, and **no override applies**. Pass `expectedNetwork` from every call site; a layer with no `network` field is unknown, not wrong. Mixing environments would otherwise pass the delta invariants too, since they compare against the same accumulated state.
- **Changed contract:** different address, **or** a `blockNumber` env states that the accumulated state does not resolve to — including when the chain carried `null` and env now has a number (explorer backfill; otherwise the indexer keeps starting that listener from the chain-level `startBlock`). Env *dropping* a `blockNumber` the chain has is **not** a change: the entry would be emitted with `blockNumber: null` and the indexer's merge takes leaf nulls literally, erasing what is published.
- **Deprecated contract:** name exists in the accumulated state for that chain with non-null `address`, but **missing** from current `env` for that chain → emit `{ address: null, blockNumber: null, txHash: null }`. Skip if a later layer already set `address: null` (avoid re-emitting every run).
- **`collectContractTags`:** skip `address === null`; no ABI for tombstones.
- **ABI gaps:** an active env contract whose required artifact names (`artifactNamesForContractKey`) appear in **no** layer's `abis` is pulled into the delta even when its address is unchanged, so the gap heals — `computeChainDelta` returns these in `abiGaps`. `checkDeltaInvariants` errors if any live contract still has no ABI after the delta, and downgrades the minimality error to a warning for a restatement that ships a missing ABI. Retired contracts need no ABI.
- **Layer cache:** published layers are immutable, so `utils/registry-fetch.js` caches them at `cache/registry-chain/<cid>.json` (gitignored, restored in CI via `actions/cache`). `REGISTRY_CHAIN_CACHE_DIR` relocates, `REGISTRY_CHAIN_NO_CACHE=1` bypasses.

## Delta invariants (`utils/registry-invariants.js`)

Structural validity does not imply a correct delta — a delta re-stating published contracts is valid JSON, which is how a near-full snapshot shipped three times. `validate-registry.js` also asserts, against the flattened chain:

- **Projection** (error): `flatten(published chain + delta)` must equal `env/*.json` — no missing change, no invented address, no wrong `blockNumber` for a contract whose blockNumber env states, no contract dropped from env without a tombstone.
- **Minimality** (error): no delta entry may restate the published address + blockNumber, and no re-tombstoning of an already-retired contract.
- **Size** (warning): delta carrying >30% of published contracts.

Skipped for `full` mode, under `SKIP_LIVE_REGISTRY_CHECK=1`, and when the chain cannot be reconstructed (warns instead — generation already fails hard there). Stats land in `summary.delta` of the sidecar and the PR comment's **Delta size** row.

## Env contracts

- Preserve **`version`** when writing env after explorer fetch (`fetchedNewData` path); stripping it breaks the next run and CI.
- Mainnet/testnet env entries should be **objects** with `address` + `version` (validator rejects bare address strings).
- `network.environment` restates the directory (`testnet-rev2` for `env/testnet-rev2/`) and `network.namespace` is required; both are checked by `validate-env-schema.js`. Neither reaches the published registry (`abi-registry.js` strips them with the other deploy-time fields).
- Switching which deployment a registry publishes (`env/registry.json`) changes every address in it — run that build with `REGISTRY_MODE=full`.

## CI

- `.github/workflows/registry.yml`: `git fetch --tags`, `npm test`, restore the `cache/registry-chain` layer cache, `validate-env-schema.js`, `validate-env-contract-version-tags.js`, `abi-registry.js`, `validate-registry.js`, PR preview comment (no separate pre-build of `./out` at deployment commit).
- **Disabled (`if: false` on `generate`) until the v3.3 deployment writes the configs.** Root-only configs read as "everything else retired" and publish tombstones for the whole protocol — that happened on 2026-08-19. Never re-enable while a published environment's configs record only `root`; `live-checks.yml` runs `validate-env-schema.js` meanwhile.

## Cursor vs Claude Code

This file is for **Claude Code** path rules. **Cursor** uses `.cursor/rules/*.mdc` (different format); this repo **gitignores** `.cursor`. Do not symlink `.cursor` to `.claude`—tools expect different filenames and frontmatter.
