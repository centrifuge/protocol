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
| `abi-registry.js` | Builds `registry/registry-{mainnet,testnet}.json` from `env/*.json`, explorer APIs, deltas vs live registry or `SOURCE_IPFS`. |
| `utils/abi-cache.js` | Per-tag Forge ABI cache (worktree + build + `out/` copy); `collectContractTags`, `findAbiInOutput`, aliases — reusable outside the registry script. |
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

- **Delta only** (not `--full`): compare each chain to **previous registry** (default live URL or `SOURCE_IPFS`).
- **Deprecated contract:** name exists on previous registry for that chain with non-null `address`, but **missing** from current `env` for that chain → emit `{ address: null, blockNumber: null, txHash: null }`. Skip if live entry already has `address: null` (avoid re-emitting every run).
- **`collectContractTags`:** skip `address === null`; no ABI for tombstones.

## Env contracts

- Preserve **`version`** when writing env after explorer fetch (`fetchedNewData` path); stripping it breaks the next run and CI.
- Mainnet/testnet env entries should be **objects** with `address` + `version` (validator rejects bare address strings).

## CI

- `.github/workflows/registry.yml`: `git fetch --tags`, `validate-env-schema.js`, `validate-env-contract-version-tags.js`, `abi-registry.js`, `validate-registry.js`, PR preview comment (no separate pre-build of `./out` at deployment commit).

## Cursor vs Claude Code

This file is for **Claude Code** path rules. **Cursor** uses `.cursor/rules/*.mdc` (different format); this repo **gitignores** `.cursor`. Do not symlink `.cursor` to `.claude`—tools expect different filenames and frontmatter.
