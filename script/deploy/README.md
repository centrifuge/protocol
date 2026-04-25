# Centrifuge Protocol – Deploy Scripts

Python-based deployment tool for the Centrifuge protocol: network config loading, contract deployment via Forge or Catapulta, and Etherscan verification.

**Run from the repository root.** The network name must match a config file in `env/<network>.json`.

---

## Prerequisites

1. **Setup**
   From repo root, run:
   ```bash
   ./script/deploy/setup.sh
   ```
   This checks (and can install) Python 3.10+, Forge, Node/npm, Catapulta, gcloud CLI, and the Google Cloud Secret Manager library.

2. **Google Cloud**
   - Authenticate: `gcloud auth login`
   - Access to project `centrifuge-production-x` for secrets (see [Adding Google secrets](#adding-google-secrets)).

3. **VERSION for deployments**
   Set `VERSION` when deploying to avoid Create3 address collisions:
   ```bash
   VERSION=v3.1.4 python3 script/deploy/deploy.py sepolia deploy:protocol
   ```

---

## Main entry: `deploy.py`

```bash
python3 script/deploy/deploy.py <network> <step> [options]
```

### Networks

Any `env/<network>.json` (e.g. `sepolia`, `base-sepolia`, `arbitrum-sepolia`, `plume`, `pharos`, `ethereum`, `anvil`). List with:

```bash
ls env/*.json
```

(Exclude the `spell/` directory.)

### Steps

| Step | Description |
|------|-------------|
| **deploy:protocol** | Deploy core protocol contracts (LaunchDeployer), then verify on Etherscan. Use `--resume` to continue after a partial run. |
| **deploy:full** | Full deployment: deploy protocol (LaunchDeployer), verify on Etherscan, then auto-deploy test data on testnets. Use `--resume` to continue after a partial run. |
| **deploy:adapters** | Deploy only adapter contracts (OnlyAdapters script), then verify and merge into network config. |
| **wire:adapters** | Wire adapters (WireAdapters script) for the given network. |
| **deploy:test** | Deploy test data (TestData script) on testnets. |
| **verify:protocol** | Verify core protocol contracts from the latest deployment (LaunchDeployer). |
| **verify:contracts** | Verify and merge all contracts from the latest deployment (no specific script). |
| **release:sepolia** | Deploy to all Sepolia testnets (sepolia, base-sepolia, arbitrum-sepolia): protocol, verify, wire, test data. Requires `VERSION`. Resumable. |
| **crosschaintest** | Full 4-step cross-chain adapter isolation test: register assets on spokes, hub setup, wait for relay, share class test. |
| **crosschaintest:hub** | Hub-side only: pool creation + adapter config (sends cross-chain messages). |
| **crosschaintest:spoke** | Spoke-side only: register assets on each spoke. |
| **crosschaintest:test** | Repeatable share class test (phase 3 of cross-chain test). |

### Options

- **`--catapulta`** – Use Catapulta for deployment instead of Forge.
- **`--ledger`** – Use Ledger hardware wallet for signing.
- **`--dry-run`** – Print what would be done without deploying.

Extra args are passed to Forge (e.g. `--resume`, `--priority-gas-price 2`).

### Examples

```bash
# Deploy protocol to Sepolia (set VERSION to avoid Create3 collisions)
VERSION=vXYZ python3 script/deploy/deploy.py sepolia deploy:protocol

# Full deploy on Base Sepolia with Catapulta and custom gas
python3 script/deploy/deploy.py base-sepolia deploy:full --catapulta --priority-gas-price 2

# Resume after a partial deploy
python3 script/deploy/deploy.py sepolia deploy:test --resume

# Verify core protocol on a network
python3 script/deploy/deploy.py sepolia verify:protocol
python3 script/deploy/deploy.py arbitrum-sepolia verify:contracts

# Release to all Sepolia testnets (network arg required but ignored; deploys to all three)
VERSION=v3.1.4 python3 script/deploy/deploy.py sepolia release:sepolia

# Cross-chain adapter isolation test (full sequence)
python3 script/deploy/deploy.py base-sepolia crosschaintest

# Repeat only the share class test (phase 3)
python3 script/deploy/deploy.py base-sepolia crosschaintest:test

# Local Anvil (self-contained; no GCP secrets needed)
python3 script/deploy/deploy.py anvil deploy:full
```

---

## Other scripts

### `update_network_config.py`

Reads deployment metadata from `broadcast/<script>/<chain_id>/run-latest.json` and merges contract addresses, block numbers, and versions into `env/<network>.json`.

```bash
python3 script/deploy/update_network_config.py <network_name> --script <script_name>
```

- `network_name` – e.g. `sepolia`, `plume`.
- `--script` – Required. Deployment script name (e.g. `LaunchDeployer`) to locate the broadcast file.

### `load_secrets.py`

Fetches all secrets from GCP Secret Manager and writes them to a `.env` file in the repo root. Preserves existing `.env` values (only fetches missing ones). No network argument required.

```bash
python3 script/deploy/load_secrets.py
```

### `add-gcp-secret.sh`

Creates or updates a secret in Google Secret Manager (project `centrifuge-production-x`). Used for RPC API keys and other deploy secrets. See [Adding Google secrets](#adding-google-secrets).

---

## Adding Google secrets

Deploy scripts read API keys and the testnet private key from **Google Cloud Secret Manager** (project `centrifuge-production-x`). Required secret names:

| Secret name | Used for |
|-------------|----------|
| `etherscan_api` | Etherscan verification |
| `alchemy_api` | RPC when `baseRpcUrl` contains `alchemy` (e.g. Sepolia, Base, Arbitrum) |
| `plume_api` | RPC when `baseRpcUrl` contains `plume` (Plume network) |
| `pharos_api` | RPC when `baseRpcUrl` contains `pharos` (Pharos via Zan) |
| `testnet-private-key` | Testnet deployer key (when not using Ledger or `.env` PRIVATE_KEY) |

### Add or update a secret

Use the helper script from `script/deploy`. Trailing newlines are always stripped, so you can press Enter or use `echo` without `-n`.

**Interactive (recommended):** run without piping; you get a hidden-input prompt, then press Enter.

```bash
# From repo root
cd script/deploy

./add-gcp-secret.sh plume_api
# Enter secret value (input hidden): <paste or type, then Enter>

./add-gcp-secret.sh pharos_api
# Enter secret value (input hidden): <paste or type, then Enter>
```

**Piped:** value from stdin (trailing newlines are stripped).

```bash
echo "YOUR_PLUME_API_KEY" | ./add-gcp-secret.sh plume_api
./add-gcp-secret.sh pharos_api < /path/to/pharos-key.txt
```

The script creates the secret if it does not exist, then adds a new version. Deploy scripts always use the **latest** version.

**Requirements:** `gcloud` CLI installed and authenticated, with access to project `centrifuge-production-x`. Override project with:

```bash
GCP_PROJECT=my-project ./add-gcp-secret.sh plume_api
```

After adding `plume_api` and `pharos_api`, deployments to networks that use Plume or Pharos RPC (e.g. `plume`, `pharos` in `env/`) will load the keys automatically.

---

## Library modules (`lib/`)

| Module | Role |
|--------|------|
| **load_config.py** | Loads `env/<network>.json`, builds RPC URL (including Alchemy/Plume/Pharos API keys from GCP), loads Etherscan key and testnet private key from GCP or `.env`. |
| **secrets.py** | GCP Secret Manager integration: fetches secrets via Python library or `gcloud` CLI fallback, can dump all secrets to `.env`. |
| **runner.py** | Runs Forge/Catapulta deploy scripts: build, auth (private key or Ledger), execution, and optional verification. |
| **verifier.py** | Compares deployed contracts to `env/<network>.json`, updates config from broadcast artifacts, and verifies contracts on Etherscan. |
| **release.py** | Orchestrates multi-network releases (e.g. `release:sepolia`): deploy, verify, wire, test data, with resumable state. |
| **crosschain.py** | Orchestrates cross-chain adapter isolation testing (`TestAdapterIsolation.s.sol`): asset registration, hub setup, relay wait, share class test. |
| **anvil.py** | Local Anvil deployment: starts Anvil, creates `env/anvil.json`, runs full protocol deploy and verification. |
| **ledger.py** | Ledger device detection and account selection for signing. |
| **formatter.py** | Terminal formatting and secret masking for deploy output. |

---

## Network config

Per-network config lives in **`env/<network>.json`**. It defines:

- `network.chainId`, `network.baseRpcUrl`, `network.environment` (testnet/mainnet)
- `network.protocolAdmin`, `network.opsAdmin`
- `network.connectsTo`, adapter config, etc.

RPC URL is built from `baseRpcUrl` plus the appropriate API key from GCP when the URL contains `alchemy`, `plume`, or `pharos`. Deployed addresses are merged into this file by the verifier and `update_network_config.py`.

---

## Logs and state

- Forge/validation logs: `script/deploy/logs/` (e.g. `forge-validate-<network>.log`).
- Release state (for `release:sepolia`): `script/deploy/logs/release_state.json`.
- Deployment data: `broadcast/<Script>.s.sol/${CHAIN_ID}/run-latest.json` (includes `deploymentMetadata` key with logical names and versions)
