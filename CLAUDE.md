# CLAUDE.md

## Project Overview
Centrifuge V3 is a DeFi RWA protocol implementing ERC7540 vaults with async/sync investment logic. Modular hub-and-spoke architecture for multi-chain tokenization with automated management capabilities.

Build and test using Foundry Forge.

### Basic Commands
```bash
forge build          # Compile contracts
forge test           # Run all tests
forge snapshot       # Create gas usage snapshots
forge coverage       # Generate coverage report
forge fmt            # Auto-format Solidity code
```

### Debugging Commands
```bash
forge test -vvv                             # Test with execution traces
forge test --match-test <test_name> -vvvv  # Debug specific test with stack traces
forge debug <test_name>                     # Interactive debugger
cast call <contract> <function> <args>      # Query contract state
cast logs --address <contract>              # Analyze emitted events
cast storage <contract> <slot>              # Inspect storage slots
```

## Hub-Spoke Architecture

### Deployment Patterns
- **Cross-chain**: Hub on Ethereum, Spokes on target chains (Base, Arbitrum, etc.)
- **Same-chain**: Both Hub and Spoke on same chain (e.g., Plume)
- **Testing assumption**: Assume hub and spoke are on same chain unless specified otherwise

### Directory Structure
```
src/
├── core/                    # Core protocol module
│   ├── hub/                # Hub-side contracts
│   │   ├── Hub.sol         # Main hub logic
│   │   ├── HubHandler.sol  # Message handling
│   │   ├── HubRegistry.sol # Pool/asset registry
│   │   ├── Accounting.sol  # Investment accounting
│   │   ├── Holdings.sol    # Asset holdings tracker
│   │   ├── ShareClassManager.sol # Share class logic
│   │   └── interfaces/
│   ├── spoke/              # Spoke-side contracts
│   │   ├── Spoke.sol       # User-facing spoke ops + balance-sheet mgmt (deposit/withdraw/issue/revoke); BatchedMulticall
│   │   ├── SpokeRegistry.sol # Pool/share-class/asset/vault registry + prices + policy + manager roles
│   │   ├── SpokeHandler.sol # Inbound cross-chain message handling
│   │   ├── SnapshotQueue.sol      # Queued share/asset deltas pending submission to the Hub (Spoke → SnapshotQueue, mirrors Hub → Holdings)
│   │   ├── PoolEscrow.sol  # Pool-specific escrow
│   │   ├── factories/      # Escrow & vault factories
│   │   └── interfaces/
│   ├── messaging/          # Message infrastructure
│   │   ├── Gateway.sol     # Cross-chain message routing
│   │   ├── MultiAdapter.sol # Multi-protocol messaging
│   │   ├── MessageProcessor.sol # Process messages
│   │   ├── MessageDispatcher.sol # Dispatch messages
│   │   └── libraries/
│   │       └── MessageLib.sol
│   ├── libraries/
│   │   └── PricingLib.sol  # Pricing calculations
│   └── utils/
│       ├── Envoy.sol       # Stable msg.sender anchor for manager calls (never redeployed)
│       └── BatchedMulticall.sol
├── deployment/             # Deploy-time only; nothing here is part of the running protocol
│   ├── ActionBatchers.sol  # Wires the protocol from their constructors; warded while deploying, then revokes itself
│   └── RootFixes.sol       # The same wiring, deferred: what only Root can do when Root was already on the chain
├── admin/                  # Admin & governance
│   ├── Root.sol           # Root authority
│   ├── OpsGuardian.sol    # Operational guardian
│   ├── ProtocolGuardian.sol # Protocol guardian
│   ├── GasService.sol     # Gas management
│   └── interfaces/
├── policies/              # Pool-level policy implementations
│   └── hub/
│       └── StdHubPolicy.sol # Default hub policy: classifies manager calls as immediate or time-locked
├── managers/              # Automation managers
│   ├── hub/
│   │   └── Supervisor.sol # Per-pool sentinel registry; sentinels veto pending authorizations
│   ├── adapters/
│   │   └── AdapterFailover.sol # Per-pool steward timelock for proposing new adapter sets
│   └── spoke/
│       ├── QueueManager.sol # Queue automation
│       ├── ShareManager.sol # Hub-driven share issuance & revocation
│       ├── OnOffRamp.sol    # On/off-ramp with accounting token support
│       ├── AccountingToken.sol # ERC-6909 tracking in-flight requests/liabilities
│       ├── FlashLoanHelper.sol # Aave V3 flash loan bridge for OnchainPM
│       ├── ScriptHelpers.sol # Weiroll script utility functions
│       └── guards/          # Bookend contracts for weiroll scripts
│           ├── ApprovalGuard.sol      # Checks zero ERC20 allowances post-script
│           ├── CircuitBreakerGuard.sol # Rolling-window rate limiter
│           └── SlippageGuard.sol      # Net value slippage checker
├── vaults/                # Vault implementations
│   ├── BatchRequestManager.sol # Batch request handling
│   ├── AsyncRequestManager.sol # Async requests
│   ├── AsyncVault.sol     # ERC-7540 async vault
│   ├── SyncDepositVault.sol # Sync deposits
│   ├── SyncManager.sol    # Sync operations
│   ├── VaultRouter.sol    # Vault routing
│   ├── BaseVaults.sol     # Base implementations
│   └── factories/
├── hooks/                 # Hook implementations
│   ├── bridge/            # Cross-chain bridging hooks
│   │   └── BridgeCircuitBreaker.sol # Pause + rate limit on outbound transfers
│   └── accounting/        # NAV & price hooks
│       ├── NAVManager.sol # NAV automation
│       └── SimplePriceManager.sol # Price automation
├── valuations/            # Asset valuations
│   ├── OracleValuation.sol # Oracle-based pricing
│   └── IdentityValuation.sol
├── bridge/                # Cross-chain token bridge
│   └── TokenBridge.sol    # Wrapper for cross-chain token transfers
├── adapters/              # Cross-chain adapters
│   ├── AxelarAdapter.sol
│   ├── ChainlinkAdapter.sol
│   ├── HyperlaneAdapter.sol
│   ├── LayerZeroAdapter.sol
│   └── StandbyAdapter.sol
├── token/                 # Share token implementations
│   ├── ShareToken.sol     # ERC20 share tokens
│   ├── ShareTokenRegistrar.sol # Deploys & operates ShareTokens (IRegistrar)
│   └── hooks/             # Share token transfer restrictions
│       ├── BaseTransferHook.sol # Base hook logic
│       ├── FreelyTransferable.sol
│       ├── FreezeOnly.sol
│       ├── FullRestrictions.sol
│       └── RedemptionRestrictions.sol
├── utils/                  # Utilities
│   ├── RefundEscrow.sol   # Refund handling
│   ├── RefundEscrowFactory.sol
│   └── SubsidyManager.sol
└── misc/                  # Utilities & types
    ├── Auth.sol          # Auth mixin
    ├── ERC20.sol         # Token standard
    ├── Escrow.sol        # Escrow logic
    ├── types/            # Custom types
    ├── libraries/        # Utility libraries
    └── interfaces/       # Standard interfaces

src-ir/                      # Contracts compiled with via_ir (stack-depth exceptions only)
└── OnchainPM.sol            # OnchainPM + OnchainPMFactory (weiroll script executor per pool)

test/                        # Tests mirror src/ structure
├── core/                 # Hub & spoke tests (unit + integration)
├── vaults/               # Vault tests (unit + integration)
├── managers/             # Manager contract tests
├── hooks/                # Transfer hook tests
├── adapters/             # Cross-chain adapter tests
├── integration/          # Cross-module integration tests
└── misc/                 # Utility & library tests

script/
├── anvil/               # Two local chains with the protocol on both, and the fixtures describing them
├── deploy/              # Launching the protocol on a chain: the deployer stack
├── setup/               # Tooling & hygiene: setup.sh (installs what a checkout needs), redact-secrets.sh.
                         # load-secrets.sh and add-gcp-secret.sh ship with the deployment configs, so not on main
├── testnet/             # Test data for a fresh deployment
├── checks/              # Repo-wide checks CI enforces (imports, ward coverage, CLAUDE.md tree, gas benchmarks).
                         # The foundry.toml network tables are checked where the configs they derive from are, not on main
└── utils/               # Shared Solidity helpers (ChainConfig, EnvConfig, JsonRegistry)
    ├── createx/         # Bindings for the externally deployed CreateX factory: ICreateX, constants, script mixin
    └── GateProposal.s.sol # Reaching the DeployGate through a Safe: EnsureDeployGate + proposeGateCall, for a
                         # namespace or delegate held by one, which the gate knows nothing about. The gate itself is a dependency —
                         # lib/create3-gate, imported as create3-gate/ — holding the contract, IDeployGate, the
                         # constants (address/salt/bytecode/codehash) and the DeployGateScript mixin. Its
                         # DeployGateScript is remapped onto utils/createx's CreateXScript, so a script
                         # inheriting both it and BaseDeployer inherits one CreateXScript rather than two.
                         # Gates deterministic CREATE3 deployments: namespace commits, executor deploys. One
                         # shared gate per chain, same address everywhere, deployable by anyone (CREATE2, so
                         # the address covers its code); per-namespace namespaces isolate users. No wards: a
                         # namespace belongs to the account it is named after, which may setDelegate() others
                         # to commit for it (one level, never transferable). Commitments are keyed by a
                         # caller-chosen id, so several can be in flight; GatedDeployer pins one
                         # (DEFAULT_COMMITMENT_ID). The commit phase brings the gate up on a chain with none

docs/
├── audits/              # Security audit reports
└── architecture/        # Contract relationship diagrams

env/                     # Where a deployment records itself, as env/<environment>/<network>.json. The
                         # directory names the environment and, after a dash, the deployment id that
                         # isolates a second deployment of the same chains (env/testnet-rev2/); a config
                         # restates it in .network.environment and the two are checked against each other.
                         # Deployment configs (testnet/, mainnet/) exist only on the `live` branch, as does
                         # everything that reads or publishes them; the base branch writes only
                         # env/anvil-<id>/, copied from script/anvil/env/ and gitignored
├── spell/               # Archive of executed spells
├── connections_viewer.html  # Draws one environment's connections.json as a graph
└── connections_viewer.sh    # Serves env/ and opens the viewer: ./env/connections_viewer.sh [environment]
```

### Async Vault Lifecycle (ERC-7540)

Async vaults implement a three-phase deposit flow:

**Phase 1: REQUEST** (`vault.requestDeposit`)
- User deposits assets into vault
- `BatchRequestManager` stores pending request
- Assets transfer to PoolEscrow (for vaults launched prior to v3.1.0, the ABI still references `globalEscrow()` which returns the pool-specific PoolEscrow)
- State: PoolEscrow ✅ receives assets | maxMint ❌

**Phase 2: PROCESS** (Two sub-phases)
- **Phase 2a: APPROVE** (`batchRequestManager.approveDeposits → spoke.noteDeposit`)
  - Admin approves pending deposits
  - `spoke.noteDeposit()` calls `escrow(poolId).deposit()` to account for assets
  - `spoke.issue()` mints shares to PoolEscrow address
  - State: PoolEscrow ✅ assets accounted, shares minted to PoolEscrow

- **Phase 2b: NOTIFY** (`batchRequestManager.notifyDeposit`)
  - Notifies users deposits are ready to claim
  - Updates `AsyncRequestManager.maxMint` allocations
  - State: PoolEscrow ❌ NO CHANGE | maxMint ✅ UPDATED

**Phase 3: CLAIM** (`vault.deposit/mint`)
- User claims allocated shares
- Shares transfer from PoolEscrow to user via `spoke.withdrawShares()`
- `AsyncRequestManager.maxMint` decreases (allocation consumed)
- State: PoolEscrow ✅ shares decrease | User balance ✅

**Async Redeem:** Analogous flow in reverse (`requestRedeem` → `approveRedeems`/`notifyRedeem` → `redeem/withdraw`), where user sends shares and receives assets.

**Sync Vaults:** All phases execute atomically in single call.

**Key Insight:** PoolEscrow holds both assets and shares. Assets are accounted during APPROVAL (Phase 2a), shares are claimed during CLAIM (Phase 3).

## Branch Model: main vs live

Two kinds of branch with different lifetimes, and every file belongs to exactly one of them. **main** is
the library: it evolves, and it defines what a deployment *is* — contracts, schemas, tests, the deployer
stack, the repo checks. **Live branches are version-pinned, one per release, and never renamed** —
`live-v3.2`, `live-v3.3`, ... — because several protocol versions can be live at the same time, each needing
its own record and tooling. A live branch holds the data its release's deployment wrote and everything that
acts on that deployment. "The live branch", here and elsewhere in this file, means the branch of whichever
release is in question; `live-v3.3` is the one main's triggers currently name.

**The decision rule for new work:**
- If it can only run against a chain that already carries the protocol, or it records what a deployment
  wrote → **live**. (Ops scripts, spells, the registry pipeline, live fork validation, `env/testnet/` and
  `env/mainnet/` configs, the public mirror's `.publicignore`.)
- If it defines or checks what a deployment is → **main**. (Everything in `src/`, the schema readers
  `ChainConfig`/`EnvConfig`, `LaunchDeployer` and the deployer stack, `script/anvil/` and its fixtures —
  the only deployment main makes — `script/checks/` and `script/setup/` except what derives from or fetches
  for the configs (`check_foundry_networks.py`, `load-secrets.sh`, `add-gcp-secret.sh`), `script/testnet/TestData`.)
- When both readings fit, prefer main: live should carry only what *cannot* be structural.
- **Name no chain on main.** Main describes mechanisms; which chains are in which case is deployment data, so
  it belongs on live with the configs. A sentence naming `plume`, `x-layer` or `base-sepolia`, a table keyed
  by network, a per-chain quirk or a per-chain workaround goes to live even when the file around it is main's
  — extract it rather than letting main accumulate a roll call it cannot check, having no configs to check it
  against. Two consequences already: `check_foundry_networks.py` ships with the configs, because the tables it
  derives are theirs (main's hold only the two anvil aliases), and `script/deploy/README.md` keeps the verifier
  *mechanism* while the list of which chains verify where sits on live. Where it cannot be helped, say why: `src/`'s
  six `MONAD_CENTRIFUGE_ID` constants are bytecode, not documentation, and they are the one place main still
  branches on a named chain.

The rule's sharpest instance: `Env.load()` is strict and describes exactly what `LaunchDeployer` deploys
from the current branch — the reader is the schema and lives on main; the configs it rejects or accepts are
data and live on live. `env/spell/` (executed-spell archive) is the one deployment record kept on main.

**CI follows the same line.** Manual and scheduled jobs keep a trigger on main — `workflow_dispatch` and
`schedule` only work from the default branch — but the trigger knows no chains: it checks out the live
branch and calls its `.github/ci-scripts/*.sh` entrypoint (`plan`/`run`), which owns the matrix, commands
and toolchain pin. `registry-publish.yml` instead calls live's `registry.yml` as a reusable workflow, since
that pipeline also runs on live on push/PR. Main names the current release's branch only inside its
trigger workflows — the `branch` input defaults (and cron fallbacks) plus `registry-publish.yml`'s literal
`uses:` refs. Cutting a new release means cutting its `live-v<version>` branch and updating those defaults;
the `branch` inputs stay overridable, so a job can still be dispatched against an older release's branch.

**Live's shape:** a branch with a history of its own, not one commit. It carries the environmental half as
additions — configs, CI entrypoints, ops scripts, spells under review — plus the main files it has to modify:
`foundry.toml`'s regenerated network tables, and today a few more (`env/README.md`, `script/deploy/README.md`,
`check_foundry_networks.py`). Getting that set down to `foundry.toml` alone is the target, not the state. It
takes main's changes by **merging main into it**, which is what makes a deletion on main a live concern: a file
main deletes and live never modified leaves live silently with that merge, and one live did modify raises a
modify/delete conflict instead — so nothing live's scripts call may leave main before live's replacement is in
place. Until the release is deployed, its configs record only `root`, and tests that need the deployed chain
skip via `SkipsUntilDeployed` — they re-arm on their own when the deployment writes the full configs back.

**Cutting a release branch:** a new `live-v<version>` is NOT a main tag pushed under a new name — a bare
tag carries none of the environmental half (entrypoints, mirror rules, spell review, ops scripts), and
every trigger would brick at its `plan` step. It is the previous live branch's environmental half brought
onto the release point, adapted to what changed under it; then main's trigger defaults and
`registry-publish.yml`'s literal refs are updated to name it.

## Deployment Info
- **Deployed versions**: recorded per release on its live branch (`env/<environment>/<network>.json` there); this branch records no deployment
- Contract addresses are deterministic across ALL networks using the standard CREATE3 deploy flow (same deployer + salt). Do NOT treat this as a protocol-enforced invariant when writing security-relevant checks: some EVM chains implement custom address-derivation logic (breaking CREATE3 determinism), the deploy flow has a legacy pre-CREATE3 salt path with no cross-chain guarantee, and the protocol aims to support non-EVM chains where "address" may not even be a comparable concept. Never validate a remote-chain address against a local-chain address as a security check.
- Find addresses in `env/<environment>/<network>.json`; every deployment that outlives a process is made from the `live` branch, and its configs live there
- **A deploy script records itself.** `JsonRegistry` (`startDeploymentOutput()` + `register()`, which `reportedSalt()` already calls — `unreportedSalt()` is the same salt without the reporting, for deploy-time only contracts like the action batchers — + `saveDeploymentOutput(path)`, the path from `Chains.pathOf` and always under `env/`) merges names, addresses, versions and block numbers straight into `env/<environment>/<network>.json`. `LaunchDeployer` does this; there is no follow-up command and no manifest. The write is a merge for every script but one: what a run does not mention is left alone, so several scripts can share one config (the ones that add to an existing deployment live on the `live` branch). `LaunchDeployer` opens its run with `startDeploymentOutput(REPLACE)`, because it brings up a protocol on a chain that has none — its set *is* the chain's contracts, so anything the config held is dropped rather than left sitting unreachable beside the new addresses. `Root`'s timelock is `DeployerInput.delay` when the run deploys one, and `AdapterFailover` takes `root.delay()` so it follows the Root actually in use — a kept Root keeps whatever governance left it. Both reach init code, so the value is derived from the config rather than the environment for the same reason `root` is. Which value is `LaunchDeployer`'s to choose, not `FullDeployer`'s — `MAINNET_DELAY` (48h) on mainnet, 0 everywhere else, so a testnet spell casts in the block it was scheduled in — since `FullDeployer` knows no networks and only takes what it is given. The one contract it keeps is `Root`, when the config records one — `ChainConfigLib.rootAddress()`, the single deployed address `ChainConfig` answers for, and the only reader that can: until a release is deployed a live config records `contracts.root` and nothing else, which is exactly the shape `Env.parseContracts` rejects, every other address being `_required`. Read from the file rather than an env var because Root is a constructor argument of nearly everything wired to it and the two gate phases have to agree on it exactly; giving a chain a fresh Root means deleting `contracts.root` first, which is why the anvil fixtures hold the input half only. A kept Root is registered at the address it already has and with no version, which is what makes `REPLACE` keep the entry, its block number included. Nothing deploys it, so the action batchers hold no ward on it and skip every `report.root.*` call they make; that wiring is deployed as `src/deployment/RootFixes.sol` instead and cast by governance over the ordinary `scheduleRely` timelock, without which the new contracts have no path from Root and the vaults are unendorsed. Like the action batchers it is submitted unreported, so `env/` never carries it; `LaunchDeployer` prints its address as its last line. A contract re-reported at the address it already had keeps its block number either way, which is what lets `--resume` finish a partial run without redating it. Only a run registering `root` writes `deploymentInfo` (gitCommit/timestamp; the deployment id is not repeated there, the directory the config sits in already names it), merged into what is there rather than replacing it. `deploymentInfo.startBlock` is recomputed on every write as the earliest `blockNumber` in the whole config, not the current run's block — a redeployment that reuses contracts leaves older ones in place, and an indexer starting after one of them misses its history. Block numbers are an **underestimate**: the write happens during forge's simulation pass, so `block.number` is the block the script read and the transactions land a few blocks later (1 on a local fork, up to ~183 on a fast chain); every contract in a run shares one. That is the safe direction for indexers and is accepted deliberately. Addresses are exact, being CREATE3-deterministic. There is no `txHash` field: it was dropped, and the registry pipeline that publishes `env/` (on the `live` branch) still emits `txHash: null` so its schema is unchanged for consumers. `env/` stays read-only to Forge (`fs_permissions`); the write goes through jq behind ffi so the guard holds for everything else. Making a new address readable back is: `register()` it in the script, add the field to `ContractsConfig` in `script/utils/EnvConfig.s.sol` (an `EnvConfig` is `chain` + `contracts`: the chain half lives in `ChainConfig.s.sol` and knows nothing of what is deployed on it, which is what a script that deploys from scratch reads). A run that deploys nothing (`LaunchDeployer --sig 'commit()'`) must not call `startDeploymentOutput()`/`saveDeploymentOutput()` at all. Registrations made during a walk that gets rolled back (`vm.revertToState`) disappear with it: the registry keeps its state in storage
- **The deployer stack is layered, and the layers mean something.** `BaseDeployer` knows CreateX, salts and the JSON registry, and **nothing about the DeployGate** — it is what an ungated script inherits. Do NOT put gate helpers, gate constants or gate checks in it, however convenient it is that everything already inherits it: a script that deploys directly has no gate and should not compile as though it might. Making a chain *have* a gate is `DeployGateScript` (`setUpDeployGate()`, `isDeployGateDeployed()`), which comes from the gate's own repository (`create3-gate/script/DeployGateScript.sol`, the `lib/create3-gate` dependency), a mixin shaped like `CreateXScript` and self-sufficient the same way — it ensures CreateX itself, so it needs no `_init()` first, and any script can inherit it alone. Getting a call into the gate from a Safe — one holding a namespace, or one a namespace delegated to — is one layer up and this repository's own, `script/utils/GateProposal.s.sol` (`proposeGateCall()`, `EnsureDeployGate`): it is what `GatedDeployer` proposes its commitment through, and what any future script reaching the gate from a Safe inherits. Deploying *through* a gate is `GatedDeployer`: `DEFAULT_COMMITMENT_ID`, `_gatedSalt()`, `gatedAddress()`, `submit()`. Each phase acts as `msg.sender` — committing, the namespace or one of its delegates; deploying, an executor — and a key sender is broadcast from while a Safe sender is proposed to (`AccountLib.isSafeAccount()` in `BaseDeployer.s.sol` asks the account, nothing else), signed by whoever holds the Ledger — an owner or proposer of the Safe, which `GateProposalScript.ledgerAddress()` reads off the device for the proposal's `sender`; the transaction service decides whether that account may propose. So a Safe namespace, a Ledger namespace delegating to a Safe, and a key delegating to a key are all the same script, and `--sender` is the only input naming who acts. `FullDeployer` adds the protocol walk, `LaunchDeployer` the network config and phases.
- There is no deployment wrapper: every intent is one forge command (see `script/deploy/README.md` for the cookbook). The network is detected from `block.chainid` via `Chains.detect()`, which `Env.load()` and `Chains.load()` call when given no name, with no override — `--rpc-url <network>` alone decides both where a run connects and which config it reads. The one input beside it is `DEPLOY_ENVIRONMENT`, and it narrows rather than overrides: when two environments describe one chain (`env/testnet/` beside `env/testnet-rev2/`), it names which directory the run means, and it is refused if it names none. A script that must pick a network *before* it has a chain passes the name to `Env.load(name)` and takes it from `NETWORK` itself; RPC URLs live in `foundry.toml` `[rpc_endpoints]` (reach one with `--rpc-url <network>` or `vm.rpcUrl(<network>)`) and verification keys in `[etherscan]`; the signer is always passed explicitly on the command line (`--private-key $PRIVATE_KEY` off mainnet; on it, `--ledger --sender <addr>` for what the admin signs and `--account <keystore-name> --sender <addr>` for the executor-signed `deploy()` phase), so `msg.sender` inside a script is the broadcaster and is what salts and wards should use. Do NOT call `vm.startBroadcast(key)` with an in-script key: that leaves `msg.sender` at forge's default sender while transactions come from the key, so a salt or ward derived from it silently belongs to the wrong account. A new network needs only `env/<environment>/<network>.json` (under an environment `Chains.environments()` lists, with an optional `-<deploymentId>` after it — a new environment is a one-line addition there): the `[rpc_endpoints]` and `[etherscan]` tables are derived from it by `check_foundry_networks.py --fix`, which ships beside the configs, and that branch's CI fails if they drift; main's own tables hold nothing but the two anvil aliases. `LaunchDeployer` has no `run()`: the gated phases are `--sig 'commit()'` and `--sig 'deploy()'`, always two separate forge runs. Local chains: `script/anvil/anvil.sh`

## Root Access & Spell Execution

There is no direct Root access on testnet or mainnet. All privileged operations require a **spell** (a contract that executes admin actions). Spells are written and reviewed on the `live` branch, pinned to the deployed version; main carries only the archive under `env/spell/`.

### Spell Execution Flow

1. **Deploy spell** - Deploy contract implementing the required admin actions
2. **Schedule rely** - Guardian calls `protocolGuardian.scheduleRely(spellAddress)` (or `opsGuardian` depending on action)
3. **Wait for delay** - Timelock delay must pass before execution
   - **Mainnet**: 48 hours (172800 seconds), `LaunchDeployer.MAINNET_DELAY`
   - **Testnet**: none. A launch off mainnet deploys `Root` with a delay of 0, so step 4 follows step 2 in the
     same block and a testnet is never held for a governance step
4. **Execute** - Call `root.executeScheduledRely(spellAddress)`
5. **Spell executes** - Root grants spell temporary ward access, spell runs, access is revoked

### Guardian Types

| Guardian         | Mainnet       | Testnet                        | Use Case                          |
| ---------------- | ------------- | ------------------------------ | --------------------------------- |
| ProtocolGuardian | Multisig Safe | EOA                            | Protocol upgrades, adapter config |
| OpsGuardian      | Multisig Safe | EOA (same as ProtocolGuardian) | Pool operations, manager updates  |

## Coding Style

Contract style, structure, and declaration-ordering conventions live in `.claude/rules/coding-style.md`, path-scoped to `src/**` so they load only when editing contracts.

## Critical Coding Rules

### Language & Compilation
- Solidity 0.8.28, Cancun EVM
- Use custom errors only: `error NotAuthorized();` (more gas efficient than string reverts)
- Prefix interfaces with `I` (e.g., `IVault`, `ISpoke`)
- Fix all compiler warnings (unused params, state mutability, unreachable code)
- Refactor "Stack too deep" errors instead of enabling `via_ir`, because `via_ir` changes compilation behavior and can mask real complexity issues. In order of preference: group parameters into structs, extract helper functions, minimize locals by reading storage/memory directly

### Access Control (Ward Pattern)

⚠️ **Primary Security Boundary** - The Ward pattern is the main access control mechanism. Missing `auth` modifiers are the most common security vulnerability.

```solidity
modifier auth() { require(wards[msg.sender] == 1, NotAuthorized()); _; }
```
- All **admin/privileged** state-changing functions require `auth` — user-facing functions (e.g., `deposit`, `requestDeposit`, `redeem`) intentionally omit it. Some contracts use role-specific guards instead (e.g., `_requireManager`/`_protected` on Spoke, `onlyManager` on NAVManager)
- Every `rely()` needs matching `deny()`, since orphaned permissions accumulate and create attack vectors
- Permission hierarchy flows from Root → All contracts

### Type System

Use custom types to prevent cross-pool operations that could route funds incorrectly:
```solidity
type PoolId is uint64;
type AssetId is uint128;
type ShareClassId is bytes16;
```
- Use custom types for all IDs (raw uints bypass the type system's protection)
- Use `CastLib.toBytes32(address)` for address→bytes32 conversion (the manual `bytes32(uint256(uint160(controller)))` pattern is error-prone)

### Core Patterns
- Asset resolution: Use `spoke.assetToId(assetAddress, tokenId)` for consistent ID lookup (for standard ERC20 assets, `tokenId` is `0`)
- Interface casting: Declare interface type explicitly before use for clarity, and verify interface compatibility before calling:

```solidity
// V2 vaults - use base interface
IBaseVault vault = IBaseVault(vaultAddress);
uint256 totalAssets = vault.totalAssets();

// V3 vaults - use ERC7540 for async operations
IERC7540Deposit vault = IERC7540Deposit(vaultAddress);
uint256 pending = vault.pendingDepositRequest(user);

// Spoke gateway operations - explicit casting
ISpokeGatewayHandler handler = ISpokeGatewayHandler(address(spoke));
handler.updateRestriction(poolId, scId, restrictionUpdate);
```

## Testing Conventions

### Structure
- **Unit tests**: Fully isolated, use `vm.mockCall` to mock all external dependencies. One contract under test, everything else mocked.
- **Integration tests**: Use `BaseTest` (inherits `FullDeployer`) to deploy the full protocol stack. Test multi-contract interactions.
- **Fork tests**: Live-state tests run from the `live` branch, which is pinned to the deployed version. Not on main.

### Common Patterns
- `vm.expectRevert(CustomError.selector)` before calls that should fail
- `vm.expectEmit()` + `emit EventName(...)` before calls that should emit
- `vm.prank(addr)` / `vm.startPrank(addr)` for caller impersonation
- `makeAddr("name")` for deterministic test addresses
- `bound(val, min, max)` for constraining fuzz inputs
- Prefer avoiding try-catch in tests; if possible, use `vm.expectRevert` instead for clearer failure assertions

## Review Checklist (Priority Order)

1. **Access Control** (highest priority): Ward pattern implementation on all admin/privileged state-changing functions
2. **CEI Compliance**: Checks→Effects→Interactions order to prevent reentrancy
3. **State Validation**: Check assumptions before operations (e.g., pool exists, sufficient balance)
4. **Custom Types**: Use PoolId, AssetId, ShareClassId instead of raw uints
5. **Cross-chain**: Verify deployment consistency across networks
6. **Coding Style conformance**: inheritance/business-logic split, control flow, SSA, LOC target, core vs periphery placement, aesthetics (see `.claude/rules/coding-style.md`)
7. **Gas & storage**: Optimize storage layout, remove redundant variables and operations

## Reference Documentation

### Foundry Resources
- [Foundry Book](https://book.getfoundry.sh) - Complete Foundry documentation
- [Best Practices Guide](https://getfoundry.sh/guides/best-practices) - Coding patterns and guidelines
- [Recon Book](https://book.getrecon.xyz/writing_invariant_tests/advanced.html) - Invariant Tests guidelines

### Architecture Documentation
- @docs/architecture/ - Contract relationship diagrams for this repository
- Visual representations of hub-spoke interactions
- Module dependency graphs and flow diagrams

### Centrifuge Protocol Documentation
- [Protocol Overview](https://docs.centrifuge.io/developer/protocol/overview/)
- [Hub Architecture](https://docs.centrifuge.io/developer/protocol/architecture/hub/)
- [Spoke Architecture](https://docs.centrifuge.io/developer/protocol/architecture/spoke/)
- [Vaults](https://docs.centrifuge.io/developer/protocol/architecture/vaults/)
- [Deployments](https://docs.centrifuge.io/developer/protocol/deployments/)
- [Multi-Chain](https://docs.centrifuge.io/user/concepts/multi-chain/)
- [Create a Pool](https://docs.centrifuge.io/developer/protocol/guides/create-a-pool/)
- [Manage a Pool](https://docs.centrifuge.io/developer/protocol/guides/manage-a-pool/)
- [Security](https://docs.centrifuge.io/developer/protocol/security/)
- [Sherlock Audit (v3.1)](https://audits.sherlock.xyz/contests/1028)

### API & Indexer
- **GraphQL API**: https://api.centrifuge.io/graphql — indexes all protocol contracts across chains
- **Source**: https://github.com/centrifuge/api-v3 — Ponder-based event indexer with 40+ entities (pools, vaults, tokens, investor transactions, holdings, cross-chain messages)
- Useful for querying on-chain state (pool data, vault status, investment flows, outstanding requests) without direct RPC calls
