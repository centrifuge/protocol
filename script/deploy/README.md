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

(Exclude `env/latest` and the `spell/` directory.)

### Steps

| Step | Description |
|------|-------------|
| **deploy:protocol** | Deploy core protocol contracts (LaunchDeployer), then verify on Etherscan. Use `--resume` to continue after a partial run. |
| **deploy:full** | Full deployment: deploy protocol (LaunchDeployer), verify on Etherscan, then auto-deploy test data on testnets. Use `--resume` to continue after a partial run. |
| **deploy:adapters** | Deploy only adapter contracts (DeployAdapters script), then verify and merge into network config. |
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

# Both phases, as two runs. Split them with DEPLOY_PHASE to sign them at different times
EXECUTORS=0xabc... NETWORK=ethereum forge script script/DeployGateDeployer.s.sol --tc DeployGateDeployer ...  # once per chain
python3 script/deploy/deploy.py ethereum verify:contracts            # merges the gate into env/ethereum.json
DEPLOY_PHASE=validate python3 script/deploy/deploy.py ethereum deploy:protocol --ledger
DEPLOY_PHASE=execute python3 script/deploy/deploy.py ethereum deploy:protocol
```

---

## Deployments go through the DeployGate

The protocol deployment is gated: the contracts are not deployed by the sender, they are deployed by a
`DeployGate`, in two phases. An **admin** commits the `(salt, init code hash)` of every contract in a single
transaction; any of the **executors** the gate holds then deploys them one by one.

| Step | Command | Signer | Transactions |
|---|---|---|---|
| Set up the gate | `EXECUTORS=<addrs> NETWORK=<network> forge script script/DeployGateDeployer.s.sol`, then `verify:contracts` to merge it into `env/<network>.json` | the admin | 1, once per chain |
| Validate | `DEPLOY_PHASE=validate ... deploy:protocol` | the admin | **1**, whatever the contract count (~2.9M gas) |
| Execute | `DEPLOY_PHASE=execute ... deploy:protocol` | an executor | one per contract |

`deploy.py` runs **both phases, as two separate forge runs**, on every network — testnets, CI and anvil
included. Setting `DEPLOY_PHASE` runs one of them, which is how a deployment separates the two in time: sign
the commitment, look at it, come back for the execute phase later.

### Reading the commitment before signing it

`validate` sends two `bytes32[]` arrays, which is nothing a hardware wallet can show you, so the phase prints
what it is about to commit to: one row per contract, and a digest of the whole set.

```
Commitment for gate 0x2e234DAe75C793f67A35089C9d99245E1C58470b
contract-version          address                                     initCodeHash
root-v3.1                 0x3640891e8fe34b03c4f78E5f147BDBdD94946F29  0x50c5b849f3f7432f8b76dbd1c65791c...
...
Validated 56 contracts in 1 transaction
Commitment digest 0x3f7a2e0c6402c5b06d8599279a7c89798db91a210e14d244239908152224f594
```

The table is generated by the run that builds the commitment, so on its own it only tells you what that run
did — it cannot vouch for itself. What makes it worth having is that **a second person can reproduce it**: the
validate phase deploys nothing, so anyone can run it against the same `NETWORK` and `SUFFIX` **without
`--broadcast`** and compare. Matching digests mean both machines built the same 56 contracts at the same
addresses from the same code; if they differ, the table says which row moved. That catches the realistic
failures — wrong network, wrong suffix, stale `out/`, an unexpected contract in the set, a local edit nobody
mentioned.

The commitment is also readable on chain afterwards: `validate` emits one `Validate(salt, initCodeHash)`
per contract, both indexed. And since nothing is deployed until the execute phase, a commitment
found to be wrong costs one re-validation, not a redeployment.

Never one run doing both. The execute phase rebuilds every init code in a fresh process and has to land on
exactly what the validate phase committed, so anything phase-dependent in a constructor argument (`msg.sender`
is the classic) makes it abort with `NotValidated`. Running the phases apart is the only thing that catches
that, which is why testnets and anvil do it the same way mainnet does. The addresses are identical either way:
the phases are about when things are signed for, never about where contracts land.

Wiring is unaffected: the action batchers still do it, and they are deployed like every other contract.

### If a run stops halfway

`validate` is a single transaction, so it either lands or it does not: if it did not, run it again. To revoke
what a commitment allows, call `validate` again: it starts a new nonce, so whatever the new call does not
mention becomes undeployable, and with no salts at all nothing is deployable. Note that dropping a *single*
salt once part of the set is on chain means calling `validate` directly with the salts you still want —
`deploy:protocol` walks the whole deployment, so it cannot rebuild a commitment whose addresses are taken. `execute`
is one transaction per contract, so it can stop partway through, and the way to pick it up is `--resume`:

```bash
DEPLOY_PHASE=execute python3 script/deploy/deploy.py <network> deploy:protocol --resume
```

Forge replays the broadcast sequence it saved instead of simulating the script again, so the transactions that
never landed are sent exactly as they were, and the gate still holds their validations: `deploy` consumes one
salt at a time, so the contracts that did not go through are untouched by the ones that did. It needs the
executor's nonce to be where the interrupted run left it, and the `broadcast/` sequence file to still be there.

What cannot be done is re-running a phase **from scratch** over a partial deployment. Without `--resume` the
script is simulated again, and it aborts on the first contract whose validation was already spent
(`Deployment does not match what was validated`). Re-validating does not get around that either: its local walk
redeploys the whole protocol, and those addresses are now taken, so CreateX reverts. So if the broadcast
sequence is gone, the executor's nonce has moved, or the simulation itself is what failed, recovery means
moving the deployment to fresh addresses — a new `SUFFIX` off mainnet, a version bump on it.

### Why the executors need no trust

A committed `(salt, init code)` pair leaves an executor no freedom. The salt fully determines the CREATE3
address and the hash fully determines the code, so an executor can only put the intended code at the
intended addresses, or revert. Authorizing several therefore costs no more trust than authorizing one: none of
them can produce anything the admin did not commit to. Committing the init code alone would **not** be safe: the executor could then
deploy validated code at an address of its choosing, consume the validation, and strand the intended address.

Deployment order needs no enforcing either. The action batchers wire from their constructors, and a call to a
contract that does not exist yet reverts, so deploying out of order reverts.

Neither does a superseded commitment linger. Every validation starts a new generation and only the live one can
be deployed from, so a set the admin replaced cannot be spent afterwards — including the salts the replacement
dropped, which would otherwise stay deployable and let an executor strand a canonical address. Validating
with no salts at all is how a pending commitment is revoked outright.

### Roles

`DeployGateDeployer` deploys the `DeployGate`, makes its sender the first admin, and seeds the executor set
from `EXECUTORS`, a required comma-separated list. The two roles are unrelated: the admin does not have to be
an executor, and an executor does not have to be an admin. The admin changes the set afterwards with
`updateExecutor(who, canDeploy)`, independently of what is committed.

- **admin** — a ward of the gate: may `validate`, and `rely`/`deny` other admins. Handing the role over
  does not move any address. The protocol `Root` is a ward too, from the gate's constructor, so governance
  can name a different admin through `relyContract` without the current one.
- **executors** — a set held on the gate, any member of which may `deploy` what the live generation
  validated, and nothing else, on any contract. They are interchangeable: none is confined to part of the
  commitment, so the phase can be split between keys or picked up by another when one becomes unavailable, and
  the deployment that comes out is the same whoever signed which part. Being separate from the commitment,
  a key is added or revoked with `updateExecutor` without disturbing what is pending, and a compromised one
  does not force a re-validation.

### Addresses

CreateX derives a CREATE3 address from its caller and the salt, and the caller is now the `DeployGate`, so:

- Addresses differ from any deployment made before this contract existed, when the sender was the caller.
  Chains already running the protocol cannot be redeployed onto their current addresses.
- Addresses stay equal across chains, because the `DeployGate` address is itself chain invariant: its salt
  embeds its deployer and no chain id. The gate enforces both properties rather than trusting the script for
  them: `validate` commits only to salts that name the gate as their guardian, which is what makes CreateX
  scope the address to it, and that leave the cross-chain redeploy protection off, which is what would
  otherwise fold the chain id in. A salt that breaks either would still deploy, and the deployment would still
  look like it worked, so it is refused at the transaction the admin signs.
- The set deploys only in the order it was committed: a commitment binds each contract to its position, so an
  executor cannot deploy one before the contracts it is wired against have been. Order was the one thing left
  for it to choose, and it is not inert — a constructor reading a dependency the deployment itself wires would
  otherwise see a different value depending on when it ran.
- Nothing is ever deployed over, and nothing already deployed is reused. This script launches a protocol on a
  chain that does not have one; it is not how a release is layered onto a live chain. Rerunning it over an
  existing deployment aborts on the first contract whose address is taken, in either phase, and that is
  deliberate: the contracts of an earlier release are warded by that release's action batchers, which denied
  themselves once they were done, so a later run could not wire them even if it were allowed to redeploy
  around them. Shipping a change to a live chain is a dedicated script plus a spell, as in
  `DeployOnchainPMV2`.
- The standalone scripts (`DeployAdapters`, `PoolHooks`, `DeployOnchainPMV2`) still salt with `msg.sender`, so
  their addresses do not derive from the gate and no longer collide with the protocol's. **Their versions must
  never overlap with `FullDeployer`'s**: a name and version those scripts share with a gated deployment now
  lands on a second, unwired address instead of reverting on a taken one, and `verify:contracts` would record
  that one over the address that is actually wired in. Moving them onto the gate as well is the real fix.

### Keys

- The gate to deploy through is `contracts.deployGate` in `env/<network>.json`, reported by
  `DeployGateDeployer` like any other deployed contract and merged in from `env/latest/` by
  `update_network_config`. Every gated phase reads it back from there, so there is nothing to pass by hand.
  It must be the same address on every chain, or protocol addresses will differ between them. Deploying
  without it in place aborts, since there is no gate to deploy through.
- The gate's own address embeds the account that ran `DeployGateDeployer`, so only that account could have taken
  it. Losing that key means losing address continuity for new chains.
- `EXECUTORS` seeds the accounts allowed to run the execute phase, read only by `DeployGateDeployer` and only
  at construction: `EXECUTORS=0xabc...,0xdef... NETWORK=<network> forge script ...`. It is required, and it
  does not default to the sender: name the keys that will run the execute phase, which can be the admin's or
  keys with no privilege anywhere else. It is not a commitment either — `updateExecutor` changes the set at any
  point, and an executor holds no privilege beyond deploying what has been validated.
- `SUFFIX` moves the gate too, and is ignored on mainnet, exactly as in `LaunchDeployer` — which is why
  `DeployGateDeployer` needs `NETWORK`, to tell one from the other. Both scripts must see the same one: an
  isolated testnet deployment gets its own gate, and that gate is built knowing the root it will deploy, so
  running them with different suffixes leaves the gate governed by a root that never exists.
- The `DeployGate` holds **no** protocol permissions at any point, so it cannot touch a live deployment.

---

## Other scripts

### `update_network_config.py`

Copies contract addresses (and block numbers from broadcast artifacts) from `env/latest/<chain_id>-latest.json` into `env/<network>.json`.

```bash
python3 script/deploy/update_network_config.py <network_name> [--script PATH]
```

- `network_name` – e.g. `sepolia`, `plume`.
- `--script` – Optional path to the deployment script (e.g. `script/LaunchDeployer.s.sol`) to derive block numbers from broadcast artifacts.

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
- Partial deployment (non verified): `env/latest/${CHAIN_ID}-latest.json`
