---
paths:
  - "script/deploy/**"
  - "script/utils/**"
  - "script/anvil/**"
  - "script/testnet/**"
  - "env/**"
  - "src/deployment/**"
  - "test/integration/chain/**"
  - "test/integration/env/**"
  - "foundry.toml"
  - ".github/workflows/**"
  # Exist only on live branches. Listed here so a live branch never has to modify this file.
  - ".github/ci-scripts/**"
  - "script/ops/**"
  - "src/spell/**"
  - "script/spell/**"
  - "test/integration/spell/**"
  - "test/integration/fork/**"
---

# Deployments, live branches and spells

Rules, and the facts answers get wrong. The mechanics are documented where they are implemented: `script/deploy/README.md` (the cookbook: every intent is one forge command), `env/README.md` (the config layout), `script/README.md`, and the natspec of `script/utils/{ChainConfig,EnvConfig,JsonRegistry}.s.sol` and `script/deploy/*.s.sol`. Read those before answering how something works.

## Live branches

- Each release has a live branch, `live-v<version>`, never renamed. It holds what that release's deployment wrote (`env/<environment>/<network>.json`, addresses included) and everything that acts on it: ops scripts, spells, the registry pipeline, fork validation, CI entrypoints, the public mirror's `.publicignore`. "The live branch" means the branch of the release in question; the current one is whichever branch main's trigger workflows default to.
- Live takes main's changes by **merging main into it**: never squash, cherry-pick or rebase main onto it. A file main deletes therefore leaves live silently if live never modified it, and raises a modify/delete conflict if it did. Never delete from main anything a live script calls before live's replacement is in place.
- Live's diff against main is additions plus one modification, `foundry.toml` (its network tables and the spell-cache permission). `delta-shape` (`script/checks/check_delta_shape.sh` on live) fails on anything else, measured from the merge-base, so a squashed sync turns every main file it touched into a live modification. Don't make a change that needs live to modify or delete another main file.
- The merge button for a PR into a live branch depends on what the PR carries on top of it; `main-merge-shape` in live's `live-checks.yml` names it in a PR comment. The table below.

| The PR | Button |
|---|---|
| no merge of main (ordinary live work) | Squash and merge |
| merges of main, nothing else | Create a merge commit |
| merges of main, each followed by at most one commit titled exactly `Required fixes after merge` | Create a merge commit |
| merges of main plus anything else | none: split it into a sync PR and a work PR |

The fix commit exists because a sync where main renamed an API live uses cannot build on either side alone. It carries only what the merge broke and never touches a main file, and it is the part a reviewer reads. Never fix inside the merge commit itself: nobody can review that.

- `Env.load()` is strict and describes exactly what `LaunchDeployer` deploys from the current branch. The reader is main's; the configs it accepts or rejects are live's. `check_foundry_networks.py`, `load-secrets.sh` and `add-gcp-secret.sh` derive from or fetch for the configs, so they ship with them on live.
- CI: `workflow_dispatch` and `schedule` only run from the default branch, so main keeps each manual or scheduled trigger. The trigger names no chain: it checks out the live branch and runs its `.github/ci-scripts/*.sh` entrypoint (`plan`/`run`), which owns the matrix, commands and toolchain pin. `registry-publish.yml` is the exception: it calls live's `registry.yml` as a reusable workflow, since that pipeline also runs on live's own pushes and PRs.
- Cutting a release: bring the previous live branch's environmental half (configs, CI entrypoints, ops scripts, mirror rules, spell review) onto the release point and adapt it to what changed. A main tag pushed as `live-v<version>` carries none of it, and every trigger would fail at its `plan` step. Then point main's trigger `branch` defaults, their cron fallbacks, and `registry-publish.yml`'s literal `uses:` refs at the new branch; the `branch` inputs stay overridable for older releases.
- Until a release is deployed, its configs record only `contracts.root`, and tests that need the deployed chain skip through `SkipsUntilDeployed`. They re-arm by themselves once the deployment writes the full configs.

## Running a deployment

- `LaunchDeployer` has no `run()`. A launch is `--sig 'commit()'` then `--sig 'deploy()'`, always two separate forge runs. Local chains: `script/anvil/anvil.sh`.
- `--rpc-url <network>` decides both where the run connects and which config it reads: `Chains.detect()` matches `block.chainid`, with no override. A script that needs a network before it has a chain passes the name to `Env.load(name)`.
- `DEPLOY_ENVIRONMENT` only narrows. When two environments describe one chain (`env/testnet/` beside `env/testnet-rev2/`) it names the directory the run means, and a value naming no directory is refused. It settles every read made by bare name: the run's own config, and a peer's deployed addresses through `Env.load(name)`, which has no scoped form and is what live's wiring scripts resolve peers with. It does not reach a peer's chain config: `Chains.load(name, environment)` reads `env/<environment>/<network>.json` and nothing else, so the connections, batch limits and adapter wiring a config is built from come from the directory that config sits in, and a name that deployment does not carry is an error rather than a sibling's file.
- Pass the signer on the command line, so `msg.sender` inside the script is the broadcaster, and derive salts and wards from `msg.sender`. Off mainnet that is `--private-key`. On mainnet it depends on who acts: a Ledger key committing (the namespace, or a delegate it named) is `--ledger --sender <addr>`; a Safe is `--sender <safe> --ffi` with no `--ledger`; the executor's `deploy()` is `--account <keystore> --sender <addr>`.
- Never pass `--ledger` when the sender is a Safe. safe-utils signs the proposal on the Ledger over ffi, and `--ledger` makes forge hold the device, so the ffi calls fail. The run reads the proposer's address off the device; set `LEDGER_DERIVATION_PATH` when the Safe's owner or proposer is not at the default `m/44'/60'/0'/0/0`, and check the path first with `cast wallet address --ledger --mnemonic-derivation-path <path>`.
- Never call `vm.startBroadcast(key)` with an in-script key. It leaves `msg.sender` at forge's default sender while transactions come from the key, so a salt or ward derived from `msg.sender` silently belongs to the wrong account.
- A new network is one file, `env/<environment>/<network>.json`, under an environment `Chains.environments()` lists, optionally suffixed `-<deploymentId>`. `foundry.toml`'s `[rpc_endpoints]` and `[etherscan]` tables are derived from it by `check_foundry_networks.py --fix` on live, whose CI fails on drift; main's tables hold only the two anvil aliases.
- A wrong admin is the unrecoverable deployment mistake; a wrong namespace is only an expensive one. The deployer trusts `protocolAdmin`, `opsAdmin` and `namespace` from the network config. A fresh chain deployed with a wrong admin burns the canonical addresses there, being CREATE3 from gate, namespace and salt: Root's guardians answer to a Safe nobody here holds, no root action and no pool is ever possible, and the chain can only move to another namespace or deployment id, off the canonical addresses for good. A wrong namespace lands a protocol at addresses nobody uses while the canonical ones stay free, so redeploying costs only gas. Rank checks and review comments in that order: admins first, namespace second.

## Recording addresses

- A deploy script records itself: `JsonRegistry` (`startDeploymentOutput()`, then `register()`, which `reportedSalt()` calls, then `saveDeploymentOutput()`) merges names, addresses, versions and block numbers into `env/<environment>/<network>.json`. Nothing runs afterwards. Deploy-time-only contracts (the action batchers, `RootFixes`) take `unreportedSalt()`, so `env/` never records them.
- To make a new address readable back, `register()` it in the script and add the field to `ContractsConfig` in `script/utils/EnvConfig.s.sol`.
- The write is a merge: what a run does not mention stays. Only `LaunchDeployer` opens with `startDeploymentOutput(REPLACE)`, since its contracts are the chain's whole protocol. A run that deploys nothing (`commit()`) must not call `startDeploymentOutput()` or `saveDeploymentOutput()`.
- Recorded block numbers are an underestimate: the block the simulation read, shared by every contract in the run. That is the safe direction for indexers and deliberate; do not "fix" it. Addresses are exact.
- A config records its contracts and nothing about the deployment as a whole. A chain's start block is the earliest `blockNumber` in it, derived by the registry when it publishes, never stored: a stored copy outlives the contracts it summarised, and a redeployment that reuses contracts leaves older ones in place that an indexer starting later would miss.

## Reading deployed state

- A zero is not a measurement until a positive control, read the same way, returns non-zero: a key known to be set, an event known to have fired. Routes that return a silent zero include a left-padded storage key, an event emitted only on a path nothing takes, an indexer entity nothing writes, and an `eth_getLogs` sweep past a provider's range cap, which some RPCs answer with an empty result instead of an error.
- Investor keys are right-padded: `CastLib.toBytes32(addr)` is `bytes32(bytes20(addr))`, the address in the high bytes. A storage probe or `cast call` keyed with the intuitive `bytes32(uint256(uint160(addr)))` reads false or zero on a key that is set, as on `BatchRequestManager.allowForceDepositCancel(poolId, scId, assetId, investor)`.
- forge and cast load `.env`, but an exported variable wins over it, so a stale export in a shell profile silently replaces the key and every `--rpc-url <network>` call 401s. Suspect that first. Prefer the `foundry.toml` aliases over ad-hoc `*_RPC_URL` variables.
- A 401, 403 or 404 from an RPC or an explorer is an access problem to report. Never route around it with an ad-hoc RPC URL, an edited `.env`, or a disabled fork test.

## Root

- A config that records `contracts.root` keeps that Root. `LaunchDeployer` reads it with `ChainConfigLib.rootAddress()`, the one deployed address `ChainConfig` answers for, and deploys a `RootFixes` holding the wiring only Root can do. Governance casts it over the ordinary `scheduleRely` timelock; until then the new contracts have no path from Root and the vaults are unendorsed. `LaunchDeployer` prints its address as its last line. To give a chain a fresh Root, delete `contracts.root` from the config first.
- A kept Root also leaves `Spoke.sender` unset, so `registerAsset` reverts: the previous release's assets have to be replayed under their old ids before anyone can register one. The launch spell files the `MessageDispatcher` after the replay. `RootFixes` never does, since governance may cast it before the spell is ready.
- Root's delay: `LaunchDeployer` passes `MAINNET_DELAY` (48 h) on mainnet and 0 everywhere else, so a testnet spell casts in the block it was scheduled in. `FullDeployer` knows no networks and takes the value it is given. `AdapterFailover` takes `root.delay()`, so a kept Root keeps whatever delay governance left it.

## Deployer stack

Each layer inherits the one before it, and the layers mean something: `BaseDeployer` knows CreateX, salts and the registry; `GatedDeployer` deploys through a DeployGate (`DEFAULT_COMMITMENT_ID`, `gatedAddress()`, `submit()`); `FullDeployer` adds the protocol walk; `LaunchDeployer` adds the network config and the phases. `DeployGateScript`, from `lib/create3-gate`, makes a chain have a gate, and `script/utils/GateProposal.s.sol` gets a call into the gate from a Safe.

- Keep gate helpers, gate constants and gate checks out of `BaseDeployer`. A script that deploys directly has no gate and must not compile as though it might.
- `--sender` is the only input naming who acts. A key sender is broadcast from; a Safe sender (`isSafeAccount()`) is proposed to, signed by whoever holds the Ledger. A Safe namespace, a Ledger namespace delegating to a Safe, and a key delegating to a key are the same script.

## Spells

- There is no direct Root access on testnet or mainnet: privileged actions go through a spell. Spells are written and reviewed on the live branch, pinned to the deployed version; main keeps only the executed-spell archive, `env/spell/`.
- Flow: deploy the spell; the guardian calls `scheduleRely(spell)` on `protocolGuardian` or `opsGuardian`; wait out `root.delay()` (48 h on mainnet, none on testnet; check with `cast call <root> "delay()(uint256)" --rpc-url <network>`); anyone calls `root.executeScheduledRely(spell)`; the spell runs with the ward that grants.
- End every spell with `root.deny(address(this))`. `executeScheduledRely` grants a ward that stays, and `root.cancelRely()` clears only the schedule.
- When a spell replaces a component, revoke the old component's permissions explicitly.
- A spell cast on several chains is deployed through CREATE3 from one deployer, so it has the same address on each.

| Guardian         | Mainnet       | Testnet                        | Use                                                 |
| ---------------- | ------------- | ------------------------------ | --------------------------------------------------- |
| ProtocolGuardian | Multisig Safe | EOA                            | Protocol upgrades                                   |
| OpsGuardian      | Multisig Safe | EOA (same as ProtocolGuardian) | Pool operations, first-time adapter sets and wiring |

Replacing a live adapter set, or re-pointing an adapter that is already wired, is nobody's: both take a spell, through `Root`. Containment does not: `blockSession` stays with the ops safe and takes a bad set offline at once.
