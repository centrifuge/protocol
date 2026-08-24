# Scripts

Grouped by what a script is *for*, since that is what decides how carefully it has to be run: bringing a
protocol up on a new chain is a different act from changing one that is already live and holding funds.

Only the first act lives here. Anything that operates on a deployment that already exists — ops scripts,
governance spells, the ABI registry pipeline — lives on the `live` branch, which is pinned to the deployed
version rather than following main.

**Run everything from the repository root.**

| Directory | What lives there |
|---|---|
| **`anvil/`** | Two local chains with the protocol on both, and the fixtures describing them. Needs no credentials and no network; this is what CI runs on every PR, and the only deployment this branch makes. See [`anvil/README.md`](anvil/README.md). |
| **`deploy/`** | Launching the protocol on a chain that does not have one. The deployer stack (`BaseDeployer` → `GatedDeployer` → `FullDeployer` → `LaunchDeployer`). Nothing brings the DeployGate up beforehand: the first run that needs one deploys it. A deploy script records its own addresses into `env/<environment>/<network>.json`, so there is no separate recording step. Every intent is one forge command — the cookbook is [`deploy/README.md`](deploy/README.md). |
| **`setup/`** | Getting a machine or a CI job ready: `setup.sh` (tools), `load-secrets.sh` (Secret Manager → `.env`, and the masking that keeps secrets out of CI logs), `redact-secrets.sh` (before anything is uploaded), `add-gcp-secret.sh`. |
| **`testnet/`** | Test data for a fresh deployment. See [`testnet/README.md`](testnet/README.md). |
| **`checks/`** | Repo-wide checks CI enforces, each with a check mode and a fix mode: import hygiene (`fix_imports.py`), ward/test coverage (`check_ward_coverage.py`), the CLAUDE.md tree (`check_claude_tree.py`), the `foundry.toml` network tables that are derived from `env/*.json` (`check_foundry_networks.py`), and the gas benchmarks that regenerate `GasService` (`benchmarks.sh`). See [`checks/README.md`](checks/README.md). |
| **`utils/`** | Shared Solidity helpers every script builds on — `ChainConfig`, `EnvConfig`, `JsonRegistry` — plus the bindings for the two factories a deployment goes through: `utils/createx/` for CreateX, `utils/gate/` for the DeployGate. Both hold only what a script needs to reach an externally deployed contract; `utils/gate/src` and `utils/gate/test` are the exception, and leave for the gate's own repository. |

## The usual paths

```bash
./script/setup/setup.sh                          # once per machine
./script/setup/load-secrets.sh                   # secrets into .env

# Deploying is plain forge — network detected from the RPC, signer passed explicitly:
set -a; . ./.env; set +a
EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast --verify

./script/anvil/anvil.sh                          # two local chains, deployed like mainnet

python3 script/checks/fix_imports.py --organize   # import hygiene, before opening a PR
```

A note on where things go: there is no deployment wrapper. A shell script exists only where a process
boundary forces one — `anvil.sh` starts anvil processes. `setup/` is separate because credentials are needed
by jobs that never deploy anything. `checks/` is separate from `utils/` because `utils/` is Solidity that
other scripts import, while `checks/` is executables that CI runs.
