## Registry automation: fixes and API key validation

### Summary

- Fixes CI failures in the registry workflow (jq parse error, env detection, Cloudflare step condition).
- Improves environment change detection so only mainnet or testnet is built when only that env changed.
- Adds a local script to validate Pinata and Cloudflare API keys without changing DNS or pinning, plus clearer docs and curl examples.

---

### Bug fixes

**Pin to IPFS step (jq parse error)**  
`pin-to-ipfs.js` logs to stdout then prints a single JSON line. The workflow was capturing all output and piping it to `jq`, which failed on the log lines. It now uses only the last line for `jq` and for `/tmp/ipfs_result.json`.

**Environment change detection**  
- Git diff was using paths `env/*.json env/**/*.json`, which git treats literally (no glob), so no files ever matched and the script always fell back to “default to both”.
- Diff path is now `env/` so any changed file under `env/` is considered.
- When no env changes are detected, we no longer default to building both; we set both to `false` so only environments with actual env file changes are built.

**Update Cloudflare step**  
The step’s `if` condition referenced `secrets.CLOUDFLARE_*`, but `secrets` is not allowed in GitHub Actions `if` expressions. The condition now only checks that at least one of mainnet or testnet CID was produced; secrets are still passed via `env:`.

---

### New: API key validation

**`script/registry/validate-api-keys.js`**  
- **Pinata:** Read-only list of pins to confirm `PINATA_JWT` works.
- **Cloudflare:** Token verify, list zones, list Web3 hostnames. Optional `--test-write` PATCHes each hostname with its current dnslink (no-op) to confirm write permission.
- Supports **account-scoped** tokens: set `CLOUDFLARE_ACCOUNT_ID` so the script uses `GET /accounts/:id/tokens/verify` instead of `/user/tokens/verify` (avoids “Invalid API Token” when the token is scoped to one account).
- Step-by-step logging (1/5 … 5/5) and a clear error when `CLOUDFLARE_ZONE_ID` is not in the token’s allowed zones.

**README**  
- “Testing API keys” section: how to run the validator, `--pinata-only` / `--cloudflare-only`, `--test-write`, and the difference between zone ID and account ID.
- Equivalent **curl** commands for Cloudflare (token verify and list Web3 hostnames) so keys can be tested without Node.

**`update-cloudflare.js`**  
- Adds `getWeb3Hostname()` for fetching a single hostname (for potential dry-run or tooling). Script already supported updating only mainnet or only testnet when only the corresponding CID is set.

---

### How to test

- **CI:** Push to a branch and confirm the registry workflow runs; on push to main with env changes, only the changed env(s) should be built; Pin to IPFS and Update Cloudflare steps should run when CIDs are produced.
- **API keys locally:**  
  `cd script/registry && npm install` then run `validate-api-keys.js` with the desired env vars (see README). Use `CLOUDFLARE_ACCOUNT_ID` if token verify fails with “Invalid API Token”.

---

### Checklist

- [ ] Registry workflow runs successfully (generate job and, when applicable, pin-to-ipfs and update-cloudflare).
- [ ] Only changed env(s) are built when env files change (mainnet-only, testnet-only, or both).
- [ ] Optional: validated Pinata and/or Cloudflare keys locally with `validate-api-keys.js` and README curl commands.
