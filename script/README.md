# Scripts

Grouped by what a script is *for*, since that is what decides how carefully it has to be run: bringing a
protocol up on a new chain is a different act from changing one that is already live and holding funds.

**Run everything from the repository root.**

| Directory | What lives there |
|---|---|
| **`deploy/`** | Launching the protocol on a chain that does not have one. The deployer stack (`BaseDeployer` → `GatedDeployer` → `FullDeployer` → `LaunchDeployer`) and `anvil.sh` for local forks. Nothing brings the DeployGate up beforehand: the first run that needs one deploys it. A deploy script records its own addresses into `env/<network>.json`, so there is no separate recording step. Every intent is one forge command — the cookbook is [`deploy/README.md`](deploy/README.md). |
| **`ops/`** | Acting on a deployment that already exists: shipping a contract to a live chain (`DeployGasService`), adding or replacing an adapter (`DeployAdapters`), connecting a new network (`WireToNewNetwork`), unpausing, pool hooks, verifying factory-built contracts. Anything here reads the protocol's live addresses out of `env/<network>.json`, so none of it can run on a chain without a deployment. Each forge script sits next to the shell wrapper that runs it across networks. |
| **`setup/`** | Getting a machine or a CI job ready: `setup.sh` (tools), `load-secrets.sh` (Secret Manager → `.env`, and the masking that keeps secrets out of CI logs), `redact-secrets.sh` (before anything is uploaded), `add-gcp-secret.sh`. |
| **`testnet/`** | Test data and the cross-chain adapter isolation test. See [`testnet/README.md`](testnet/README.md). |
| **`spell/`** | Governance spells, moved to `env/spell/` once executed. |
| **`registry/`** | The ABI registry pipeline (Node). See [`registry/README.md`](registry/README.md). |
| **`checks/`** | Repo-wide checks CI enforces, each with a check mode and a fix mode: import hygiene (`fix_imports.py`), ward/test coverage (`check_ward_coverage.py`), the CLAUDE.md tree (`check_claude_tree.py`), the `foundry.toml` network tables that are derived from `env/*.json` (`check_foundry_networks.py`), and the gas benchmarks that regenerate `GasService` (`benchmarks.sh`). See [`checks/README.md`](checks/README.md). |
| **`utils/`** | Shared Solidity helpers every script builds on — `EnvConfig`, `JsonRegistry`, GraphQL — plus the bindings for the two factories a deployment goes through: `utils/createx/` for CreateX, `utils/gate/` for the DeployGate. Both hold only what a script needs to reach an externally deployed contract; `utils/gate/src` and `utils/gate/test` are the exception, and leave for the gate's own repository. |

## The usual paths

```bash
./script/setup/setup.sh                          # once per machine
./script/setup/load-secrets.sh                   # secrets into .env

# Deploying is plain forge — network detected from the RPC, signer passed explicitly:
set -a; . ./.env; set +a
EXECUTORS=<address> forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast
forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url sepolia --private-key $PRIVATE_KEY --broadcast --verify

./script/deploy/anvil.sh                         # two local forks, deployed like mainnet
./script/testnet/crosschaintest.sh base-sepolia  # cross-chain adapter isolation test

python3 script/checks/fix_imports.py --organize   # import hygiene, before opening a PR
```

A note on where things go: there is no deployment wrapper. A shell script exists only where a process
boundary forces one — `anvil.sh` starts anvil processes, `crosschaintest.sh` spans networks and waits for
relays, the `ops/` wrappers loop one forge script over many networks. `setup/` is separate because
credentials are needed by jobs that never deploy anything, such as the fork tests. `checks/` is separate from
`utils/` because `utils/` is Solidity that other scripts import, while `checks/` is executables that CI runs.
