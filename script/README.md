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
| **`utils/`** | Shared Solidity helpers every script builds on — `ChainConfig`, `EnvConfig`, `JsonRegistry` — plus what a deployment needs to reach the two factories it goes through. CreateX is `utils/createx/`, a copy of [createx-forge](https://github.com/radeksvarz/createx-forge)'s script files without their console.log lines. The DeployGate is a dependency instead, [create3-gate](https://github.com/centrifuge/create3-gate) in `lib/`, imported as `create3-gate/`; `remappings.txt` points its `DeployGateScript` at the CreateXScript copy above, so a script inheriting both it and `BaseDeployer` inherits one CreateXScript rather than two. `utils/GateProposal.s.sol` is what this repository adds on top of the gate: reaching it through a Safe, which the gate knows nothing about. |

## The usual paths

```bash
./script/setup/setup.sh                          # once per machine
./script/setup/load-secrets.sh                   # secrets into .env

# Deploying is plain forge — network detected from the RPC, signer passed explicitly:
set -a; . ./.env; set +a
EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'commit()' --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()'  --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast --verify

./script/anvil/anvil.sh                          # two local chains, deployed like mainnet

python3 script/checks/fix_imports.py --organize   # import hygiene, before opening a PR
```

A note on where things go: there is no deployment wrapper. A shell script exists only where a process
boundary forces one — `anvil.sh` starts anvil processes. `setup/` is separate because credentials are needed
by jobs that never deploy anything. `checks/` is separate from `utils/` because `utils/` is Solidity that
other scripts import, while `checks/` is executables that CI runs.
