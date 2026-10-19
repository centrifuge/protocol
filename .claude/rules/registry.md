---
paths:
  - "script/registry/**"
  - "env/**/*.json"
  - ".github/workflows/registry.yml"
  - ".github/ci-scripts/detect-*.js"
---

# Contract registry scripts (`script/registry/`)

**Source of truth for behavior and schema:** [script/registry/README.md](../../script/registry/README.md). Prefer updating that README when behavior or flags change. **ABI cache directory layout** is documented there (“ABI cache layout (repo root)”) for humans and AI tools.

## Layout

| Area | Role |
|------|------|
| `abi-registry.js` | Builds `registry/registry-{mainnet,testnet}.json` from `env/*.json` (block numbers included: it reads no explorer), deltas vs the flattened published chain (walked from the live registry or `SOURCE_IPFS`). |
| `utils/registry-chain.js` | Walks `previousRegistry.ipfsHash` to the base snapshot and flattens layers into the accumulated published state. Call `collectRegistryChain` and take its `accumulated` — it flattens for you; `flattenRegistryChain` is exported for tests and requires oldest → newest ordering. |
| `utils/registry-fetch.js` | **All** published-registry network I/O: `REGISTRY_URLS`, `DNSLINK_HOSTNAMES`, `IPFS_GATEWAYS`, `isValidIpfsHash`, `resolveLiveCid`, `fetchRegistryFromIpfs`, `fetchLiveRegistry`, CID layer cache. Never declare these a second time elsewhere. |
| `utils/registry-delta.js` | Delta membership against the accumulated state: `hasContractChanged`, `computeChainDelta` (returns `changed`, `kept`, `abiGaps`; never a tombstone). The generator logs kept contracts as a count; `REGISTRY_VERBOSE=1` lists them. |
| `utils/registry-retirements.js` | Explicit retirement: `chainAddressHistory` (every address a chain published, by layer), `flattenRetired`, `computeChainRetirements` (expands a network's `retired.json` declarations into the addresses a layer closes, with validation), `declarationErrors` (shape check), `openAddressesOutsideEnv` (what a snapshot would drop). |
| `utils/registry-invariants.js` | `checkDeltaInvariants` (projection / minimality / size), `loadEnvChains`. |
| `utils/env-dirs.js` | Which `env/` directory each registry publishes: `env/registry.json` (`resolveEnvironmentDir`, `envFilesOf`, `allEnvFiles`), and the files beside the configs: `versions.json` (`versionAliasesOf`), `retired.json` (`retirementsOf`). **Never enumerate `env/mainnet`/`env/testnet` by hand** — `env/testnet-<id>/` directories are other deployments of the same chains, and only the pointed one is published. |
| `walk-registry-chain.js` | Ops CLI: per-layer chain audit (contracts, tombstones and retirements per layer, flags snapshot-sized layers). |
| `test/` | `node:test` suite, no extra deps: `cd script/registry && npm test`. |
| `utils/abi-cache.js` | Per-tag Forge ABI cache (worktree + build + `out/` copy); `collectContractTags`, `findAbiInOutput`, `resolveArtifactName` / `artifactNamesForContractKey` (single `ABI_NAME_ALIASES` table) — reusable outside the registry script. |
| `build-abi-cache.js` | CLI: `node script/registry/build-abi-cache.js <tag> [...]` to warm `cache/abi-registry/`. |
| `utils/tag-resolution.js` | Maps env contract `version` → local git tag (`resolveVersionTag`, candidates); an `env/<dir>/versions.json` alias replaces the candidates. |
| `utils/validate-env-contract-version-tags.js` | CI: every mainnet/testnet contract object must have `version` resolving to a git tag, and every alias in a `versions.json` must redirect a version some contract records. |
| `validate-env-schema.js` | CI: structural validation of `env/*.json` before generation. |
| `validate-registry.js` | Post-generation indexer checks, including the shape of `chains.<id>.retired`; `.validation.json` sidecar for PR comments. Skips ABI/address rules for old `address: null` tombstones. |
| `pin-to-ipfs.js`, `validate-api-keys.js`, etc. | Pinning and local API checks; see README table. |

## ABI generation

- **`utils/abi-cache.js`** owns the per-tag cache (`ensureAbiCache`, `collectContractTags`, …); `abi-registry.js` and `build-abi-cache.js` call into it.
- ABIs come from **per-contract `version` in env** → resolved git tag → `cache/abi-registry/<tag>/out/` (worktree + `forge build --skip test`). Not from a single deployment commit’s `out/`.
- **`env/<dir>/versions.json`** (`{ "tags": { "v3.3": "v3.3.0-rc2" } }`, `versionAliasesOf` in `utils/env-dirs.js`) is how a deployment made before its release was tagged points at the candidate it runs. Scoped to that directory and replaces the candidate list. Nothing checks it against the deployed source — a config records no deployment commit — so the alias is the deployment's own claim and is reviewed as one.
- **`chains.<id>.deployment.startBlock`** is the only deployment metadata the registry carries, derived at publish time as the earliest `blockNumber` among every active contract the config records (not only the delta's). There is no top-level `deploymentInfo` and no `deployedAt`. Configs hold `network`, `adapters` and `contracts` only — `validate-env-schema.js` rejects any other top-level key.
- After `packAbis`, **`stripContractVersionsForRegistryOutput`** removes per-contract `version` from serialized JSON (smaller artifacts); **`version` stays in repo `env/*.json`**.

## Delta mode & retirement

- **Delta only** (not `--full`): compare each chain to the **accumulated state of the whole published chain** — `collectRegistryChain` + `flattenRegistryChain` from the tip (live URL or `SOURCE_IPFS`) back to the base snapshot, newest layer winning. **Never compare against the tip document alone:** each layer carries only its own changes, so that inflates the delta to a near-full snapshot, makes successive publishes oscillate between complementary halves of the contract set, and loses the retirements already in force.
- **Incomplete chain** (broken pointer, unreachable layer, cycle, depth bound) → **exit non-zero**; `ALLOW_PARTIAL_REGISTRY_CHAIN=1` overrides, `REGISTRY_CHAIN_MAX_DEPTH` raises the fetch bound (default 500; testnet is already ~50 layers).
- **Unreadable tip** (live endpoint + dnslink fallback both down, or unfetchable `SOURCE_IPFS`) → **exit non-zero, no override**: with no baseline every contract reads as new *and* `previousRegistry` stays null, so an outage would pin itself as a base registry. Use `REGISTRY_MODE=full` to publish a base snapshot deliberately.
- **CID hygiene:** `previousRegistry.ipfsHash` comes from published documents, so `fetchRegistryFromIpfs` refuses anything that is not a plain alphanumeric segment before it reaches a gateway URL or the `cache/registry-chain/<cid>.json` path.
- **Wrong-network layer** → `collectRegistryChain` returns `fatal: true` with an empty state, and **no override applies**. Pass `expectedNetwork` from every call site; a layer with no `network` field is unknown, not wrong. Mixing environments would otherwise pass the delta invariants too, since they compare against the same accumulated state.
- **Changed contract:** different address, **or** a `blockNumber` env states that the accumulated state does not resolve to — including when the chain carried `null` and env now has a number (a later correction; otherwise the indexer keeps starting that listener from the chain-level `startBlock`). Env *dropping* a `blockNumber` the chain has is **not** a change: the entry would be emitted with `blockNumber: null` and the indexer's merge takes leaf nulls literally, erasing what is published.
- **Missing from env is not retirement.** A contract live in the accumulated state but absent from env is **kept** as published (`computeChainDelta` returns it in `kept`; the generator logs it, the projection invariant reports it in `stats.keptByChain`, not as a warning, and the PR preview lists it). Env is written by deploy scripts that record what they deployed: a release's `REPLACE` run drops every contract it did not redeploy, and a cleanup can drop a key, with no bearing on whether the contract is in use. Tombstoning on absence is what retired the v3.1 on/off-ramp factory while 93 managers still used it (#407). Never reintroduce it.
- **Retirement is declared, per chain**, in `env/<environment>/retired.json` beside the configs (`utils/env-dirs.js`, `retirementsOf`), keyed by network name and resolved through the configs in that directory: a key matching no `<network>.json` is an error, never a skip. A config records the deployment and nothing else, so `validate-env-schema.js` refuses a `retired` key inside one. Under a network, a key is a layer version (`"v3.2.0": { endBlock, except?: [name | address], reason? }`) or one address (`"0x…": { endBlock, reason? }`). `utils/registry-retirements.js` expands both into the same published shape under the chain, `retired: { "<lowercase address>": { contract, blockNumber?, endBlock } }`, so the published schema never depends on how the declaration was written. A version closes every address a layer at or before its last layer published, except those env still lists, a later layer republishes, `except` names, or a tombstone shadowed; an address declaration closes that address and overrides a version for it. The file is a ledger: declarations stay once published and are idempotent across publishes (same `endBlock` → in force, not re-emitted, logged as a note; changed → emitted as a correction). Only `vX.Y.Z` labels are accepted as version keys (`v3.1.0`, `v3.2.0` of the labels published so far); older layers are reached by address. Errors: unknown version, `endBlock` before an address's deploy block, closing an address env lists, an unpublished address, an `except` entry matching nothing. Closing nothing at all is a warning. Keyed by address because a name is reused across releases. A fully migrated chain needs no `except`: the migration re-announces tokens and vaults on the v3.3 `spokeRegistry`; `except` is for a pool left behind.
- **Old tombstones** (`address: null`) stay valid in published layers and still shadow; `collectContractTags` skips them (no ABI). The generator just never writes new ones.
- **Full mode reads the chain too** and refuses a snapshot that would drop published, live, unretired addresses (`openAddressesOutsideEnv`), since an indexer rebuilding from it would lose their history; `ALLOW_HISTORY_DROP=1` is for replacing the published deployment on purpose. Retirements are carried forward into the snapshot.
- **ABI gaps:** an active env contract whose required artifact names (`artifactNamesForContractKey`) appear in **no** layer's `abis` is pulled into the delta even when its address is unchanged, so the gap heals — `computeChainDelta` returns these in `abiGaps`. `checkDeltaInvariants` errors if any live contract still has no ABI after the delta, and downgrades the minimality error to a warning for a restatement that ships a missing ABI. Retired contracts need no ABI.
- **Layer cache:** published layers are immutable, so `utils/registry-fetch.js` caches them at `cache/registry-chain/<cid>.json` (gitignored, restored in CI via `actions/cache`). `REGISTRY_CHAIN_CACHE_DIR` relocates, `REGISTRY_CHAIN_NO_CACHE=1` bypasses.

## Delta invariants (`utils/registry-invariants.js`)

Structural validity does not imply a correct delta — a delta re-stating published contracts is valid JSON, which is how a near-full snapshot shipped three times. `validate-registry.js` also asserts, against the flattened chain:

- **Projection** (error): `flatten(published chain + delta)` must carry every contract `env/*.json` lists, at env's address and blockNumber — no missing change, no invented address. Contracts published but absent from env are kept and reported (`stats.keptContracts`, `stats.keptByChain`), not warned about, unless retired.
- **Retirements** (error): a `retired` entry must not close an address env lists as live, must name an address the chain published (checked when `publishedAddresses` is supplied), and must not restate a published retirement; a changed `endBlock` is a correction and warns.
- **Minimality** (error): no delta entry may restate the published address + blockNumber, and no re-tombstoning of an already-retired contract.
- **Size** (warning): delta carrying >30% of published contracts.

Skipped for `full` mode, under `SKIP_LIVE_REGISTRY_CHECK=1`, and when the chain cannot be reconstructed (warns instead — generation already fails hard there). Stats land in `summary.delta` of the sidecar and the PR comment's **Delta size** row.

## Env contracts

- Every contract entry carries a numeric **`blockNumber`**; `validate-env-schema.js` rejects one without, and the registry derives `deployment.startBlock` from them rather than asking an explorer.
- Mainnet/testnet env entries should be **objects** with `address` + `version` (validator rejects bare address strings).
- A directory may carry `retired.json` (see **Delta mode & retirement** above); `validate-env-schema.js` checks it: every key is a network with a config in that directory, and each declaration has a positive integer `endBlock`, an optional `reason`, and on a version key an optional `except` list of contract names or addresses (`declarationErrors` in `utils/registry-retirements.js`). Nothing in `src/` or the deployer reads it, and `detect-changed-environments.js` treats a change to it like a config change.
- `network.environment` restates the directory (`testnet-rev2` for `env/testnet-rev2/`) and `network.namespace` is required; both are checked by `validate-env-schema.js`. Neither reaches the published registry (`abi-registry.js` strips them with the other deploy-time fields).
- Switching which deployment a registry publishes (`env/registry.json`) changes every address in it — run that build with `REGISTRY_MODE=full`.

## CI

- `.github/workflows/registry.yml`: `git fetch --tags`, `npm test`, restore the `cache/registry-chain` layer cache, `validate-env-schema.js`, `validate-env-contract-version-tags.js`, `abi-registry.js`, `validate-registry.js`, PR preview comment (no separate pre-build of `./out` at deployment commit).
- **`generate` runs before the v3.3 deployment writes the configs and publishes nothing until then.** Root-only configs used to read as "everything else retired" and publish tombstones for the whole protocol — that happened on 2026-08-19. Since absence no longer retires anything, such a run yields a delta with no changed chain, which `summary.publishable` marks false and the pin step drops. Ordering: `generate` on `live-v3.2` is disabled first (#462; its generator still tombstones on absence and would undo a v3.3 layer on its next env push; no v3.2 deployment is published after that). api-v3#499 gates api-v3 moving `REGISTRY_URL` to a v3.3 layer, not publishing one.

## Cursor vs Claude Code

This file is for **Claude Code** path rules. **Cursor** uses `.cursor/rules/*.mdc` (different format); this repo **gitignores** `.cursor`. Do not symlink `.cursor` to `.claude`—tools expect different filenames and frontmatter.
