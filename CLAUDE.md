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
│   └── ActionBatchers.sol  # Wires the protocol from their constructors; warded while deploying, then revokes itself
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
├── spell/                  # Governance spells (archived under env/spell/ after execution)
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
├── integration/          # Cross-module integration & fork tests & spell tests
└── misc/                 # Utility & library tests

script/
├── deploy/              # Launching the protocol on a chain: the deployer stack + anvil.sh for local forks
├── ops/                 # Acting on a deployment that already exists (upgrades, wiring, unpause, one-offs)
├── setup/               # Credentials & hygiene: setup.sh, load-secrets.sh, redact-secrets.sh
├── testnet/             # Test data & cross-chain adapter tests
├── spell/               # Spell execution scripts
├── registry/            # ABI registry pipeline (Node)
├── checks/              # Repo-wide checks CI enforces (imports, ward coverage, CLAUDE.md tree, foundry.toml network tables, gas benchmarks)
└── utils/               # Shared Solidity helpers (EnvConfig, JsonRegistry)
    ├── createx/         # Bindings for the externally deployed CreateX factory: ICreateX, constants, script mixin
    └── gate/            # Same shape for the DeployGate: IDeployGate, constants (address/salt/bytecode/codehash),
                         # DeployGateScript mixin. src/ and test/ hold the contract and its unit test until
                         # they move to their own repo, and are the only part that goes: the bindings above
                         # them stay, exactly as createx/ has no CreateX.sol.
                         # Gates deterministic CREATE3 deployments: validator commits, executor deploys. One
                         # shared gate per chain, same address everywhere, deployable by anyone (CREATE2, so
                         # the address covers its code); per-validator namespaces isolate users. No wards: a
                         # namespace belongs to the account it is named after, which may setDelegate() others
                         # to commit for it (one level, never transferable). Commitments are keyed by a
                         # caller-chosen id, so several can be in flight; GatedDeployer pins one
                         # (DEFAULT_COMMITMENT_ID). The validate phase brings the gate up on a chain with none

docs/
├── audits/              # Security audit reports
└── architecture/        # Contract relationship diagrams

env/                     # Deployed contract addresses, archived spells
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

## Deployment Info
- **Current Version**: v3.1.0 (see `env/*.json` for network-specific details)
- Contract addresses are deterministic across ALL networks using the standard CREATE3 deploy flow (same deployer + salt). Do NOT treat this as a protocol-enforced invariant when writing security-relevant checks: some EVM chains implement custom address-derivation logic (breaking CREATE3 determinism), the deploy flow has a legacy pre-CREATE3 salt path with no cross-chain guarantee, and the protocol aims to support non-EVM chains where "address" may not even be a comparable concept. Never validate a remote-chain address against a local-chain address as a security check.
- Find addresses in `env/*.json` (e.g., `env/ethereum.json`)
- **A deploy script records itself.** `JsonRegistry` (`startDeploymentOutput()` + `register()`, which `reportedSalt()` already calls — `unreportedSalt()` is the same salt without the reporting, for deploy-time only contracts like the action batchers — + `saveDeploymentOutput(network)`) merges names, addresses, versions and block numbers straight into `env/<network>.json`. The deploying scripts — `LaunchDeployer`, `DeployAdapters`, `DeployGasService` — each do this; there is no follow-up command and no manifest. The write is a merge for every script but one: what a run does not mention is left alone, so several scripts share one config. `LaunchDeployer` opens its run with `startDeploymentOutput(REPLACE)`, because it brings up a protocol on a chain that has none — its set *is* the chain's contracts, so anything the config held is dropped rather than left sitting unreachable beside the new addresses. A contract re-reported at the address it already had keeps its block number either way, which is what lets `--resume` finish a partial run without redating it. Only a run registering `root` writes `deploymentInfo` (gitCommit/timestamp/suffix), merged into what is there rather than replacing it. `deploymentInfo.startBlock` is recomputed on every write as the earliest `blockNumber` in the whole config, not the current run's block — a redeployment that reuses contracts leaves older ones in place, and an indexer starting after one of them misses its history. Block numbers are an **underestimate**: the write happens during forge's simulation pass, so `block.number` is the block the script read and the transactions land a few blocks later (1 on a local fork, up to ~183 on a fast chain); every contract in a run shares one. That is the safe direction for indexers and is accepted deliberately. Addresses are exact, being CREATE3-deterministic. There is no `txHash` field: it was dropped. `script/registry/abi-registry.js` still asks explorers for creation info (`fetchContractCreationInfo`, and the Routescan/Plume variants), but only for a contract whose `blockNumber` is missing from `env/`, and it keeps only the block number — the `txHash` in the answer is what the Avalanche and Plume fetchers look the transaction up by, never something written back. The published registry still emits `txHash: null`, so its schema is unchanged for consumers. `env/` stays read-only to Forge (`fs_permissions`); the write goes through jq behind ffi so the guard holds for everything else. Making a new address readable back is: `register()` it in the script, add the field to `ContractsConfig` in `script/utils/EnvConfig.s.sol`. A run that deploys nothing (`LaunchDeployer --sig 'validate()'`) must not call `startDeploymentOutput()`/`saveDeploymentOutput()` at all. Registrations made during a walk that gets rolled back (`vm.revertToState`) disappear with it: the registry keeps its state in storage
- **The deployer stack is layered, and the layers mean something.** `BaseDeployer` knows CreateX, salts and the JSON registry, and **nothing about the DeployGate** — it is what an ungated script (`DeployAdapters`, `DeployGasService`, `PoolHooks`) inherits. Do NOT put gate helpers, gate constants or gate checks in it, however convenient it is that everything already inherits it: a script that deploys directly has no gate and should not compile as though it might. Making a chain *have* a gate is `script/utils/gate/DeployGateScript.sol` (`setUpDeployGate()`, `isDeployGateDeployed()`), a mixin shaped like `CreateXScript` and self-sufficient the same way — it ensures CreateX itself, so it needs no `_init()` first, and any script can inherit it alone (`ProposeSetDelegate` does). Deploying *through* a gate is `GatedDeployer`: `DEFAULT_COMMITMENT_ID`, `_gatedSalt()`, `gatedAddress()`, `submit()`. `FullDeployer` adds the protocol walk, `LaunchDeployer` the network config and phases.
- There is no deployment wrapper: every intent is one forge command (see `script/deploy/README.md` for the cookbook). The network is detected from `block.chainid` via `Env.load()`/`Env.detect()`, with no override — `--rpc-url <network>` alone decides both where a run connects and which config it reads. A script that must pick a network *before* it has a chain (`VerifyFactoryContracts`, which reads a config to know where to fork) passes the name to `Env.load(name)` and takes it from `NETWORK` itself; RPC URLs live in `foundry.toml` `[rpc_endpoints]` (reach one with `--rpc-url <network>` or `vm.rpcUrl(<network>)`) and verification keys in `[etherscan]`; the signer is always passed explicitly on the command line (`--private-key $PRIVATE_KEY` off mainnet; on it, `--ledger --sender <addr>` for what the admin signs and `--account <keystore-name> --sender <addr>` for the executor-signed `execute()` phase), so `msg.sender` inside a script is the broadcaster and is what salts and wards should use. Do NOT call `vm.startBroadcast(key)` with an in-script key: that leaves `msg.sender` at forge's default sender while transactions come from the key, so a salt or ward derived from it silently belongs to the wrong account. A new network needs only `env/<network>.json`: the `[rpc_endpoints]` and `[etherscan]` tables are derived from it by `python3 script/checks/check_foundry_networks.py --fix`, and CI fails if they drift. `LaunchDeployer` has no `run()`: the gated phases are `--sig 'validate()'` and `--sig 'execute()'`, always two separate forge runs. Local forks: `script/deploy/anvil.sh`; cross-chain test: `script/testnet/crosschaintest.sh`

## Root Access & Spell Execution

There is no direct Root access on testnet or mainnet. All privileged operations require a **spell** (a contract that executes admin actions).

### Spell Execution Flow

1. **Deploy spell** - Deploy contract implementing the required admin actions
2. **Schedule rely** - Guardian calls `protocolGuardian.scheduleRely(spellAddress)` (or `opsGuardian` depending on action)
3. **Wait for delay** - Timelock delay must pass before execution
   - **Mainnet**: 48 hours (172800 seconds)
   - **Testnet**: 5 minutes (300 seconds)
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
- **Fork tests**: Use mainnet/testnet state via `vm.createSelectFork`. Organized under `test/integration/fork/`.

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
