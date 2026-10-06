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
```

Format with the full chain, not `forge fmt` alone: it drops unused imports, then orders them and makes them relative, which CI checks beside `forge fmt --check`.
```bash
python3 script/checks/fix_imports.py --fix-unused && python3 script/checks/fix_imports.py --organize && forge fmt
```

### Debugging Commands
```bash
forge test -vvv                                  # Test with execution traces
forge test --match-test <test_name> -vvvv       # Debug specific test with stack traces
forge test --match-test <test_name> --debug     # Interactive debugger
cast call <contract> <function> <args>           # Query contract state
cast logs --address <contract>                   # Analyze emitted events
cast storage <contract> <slot>                   # Inspect storage slots
```

## Hub-Spoke Architecture

### Deployment Patterns
- **Cross-chain**: the Hub on one chain, Spokes on the others
- **Same-chain**: Hub and Spoke on the same chain
- **Testing assumption**: Assume hub and spoke are on same chain unless specified otherwise

### Directory Structure
Each module under `src/` has a `README.md` describing its contracts and flows; read it before working in the module. The tree lists only what a filename does not tell you; find everything else with Glob.
```
src/
├── core/
│   ├── spoke/
│   │   ├── Spoke.sol           # also balance-sheet management (deposit/withdraw/issue/revoke); there is no BalanceSheet contract
│   │   ├── SpokeRegistry.sol   # also prices, policy and manager roles
│   │   ├── SnapshotQueue.sol   # share/asset deltas pending submission to the Hub; spoke-side mirror of Hub → Holdings
│   │   └── Escrow.sol          # the per-pool escrow, holding its assets and shares per share class
│   └── utils/
│       └── Envoy.sol           # stable msg.sender anchor for manager calls; never redeployed
├── deployment/                 # deploy-time only; nothing here is part of the running protocol
│   ├── ActionBatchers.sol      # wires the protocol from their constructors; warded while deploying, then revokes itself
│   ├── Currencies.sol          # the ISO 4217 currencies every deployment registers for pools to denominate in
│   └── RootFixes.sol           # the same wiring, deferred: what only Root can do when Root was already on the chain
├── policies/
│   └── hub/
│       └── StdHubPolicy.sol    # classifies manager calls as immediate or time-locked
├── managers/
│   ├── hub/
│   │   └── Supervisor.sol      # per-pool sentinels that veto pending authorizations
│   ├── adapters/
│   │   └── AdapterFailover.sol # per-pool steward timelock for proposing new adapter sets
│   └── spoke/
│       ├── AccountingToken.sol # ERC-6909 tracking in-flight requests and liabilities
│       ├── FlashLoanHelper.sol # Aave V3 flash loan bridge for OnchainPM
│       └── guards/             # bookend contracts that check state after a weiroll script
├── hooks/
│   └── bridge/
│       └── BridgeCircuitBreaker.sol # pause and rate limit on outbound transfers
└── token/
    └── ShareTokenRegistrar.sol # deploys and operates ShareTokens (IRegistrar)

src-ir/                         # contracts compiled with via_ir, stack-depth exceptions only
└── OnchainPM.sol               # OnchainPM + OnchainPMFactory: weiroll script executor per pool

test/                           # mirrors src/

certora/                        # submodule (centrifuge/protocol-certora): the Certora formal verification, CVL specs,
                                # harnesses, prover confs and 1,445 mutants. Opt-in: `.gitmodules` marks it `update = none`, so
                                # clones, `submodule update --init` and CI checkouts leave it an empty directory. Only
                                # running the prover needs it: `git submodule update --init --checkout certora`
```

### Async Vault Lifecycle (ERC-7540)
A deposit, step by step (detail in `src/vaults/README.md`):
1. **Request** (`vault.requestDeposit`): `AsyncRequestManager` calls `spoke.noteDeposit`, a reservation the hub does not account for yet, and the vault moves the assets into the pool's `Escrow`.
2. **Approve** (`ManagerAction.ApproveDeposits`, arriving at `BatchRequestManager.fromHub`, which only the `Envoy` may call): the hub's callback runs `spoke.unreserve`, and the assets enter the hub-accounted holding.
3. **Issue** (`ManagerAction.IssueShares`): the callback mints the shares to the `Escrow` (`spoke.issue`).
4. **Notify** (`BatchRequestManager.notifyDeposit`, callable by anyone): the callback raises the controller's `maxMint` in `AsyncRequestManager`.
5. **Claim** (`vault.deposit`/`mint`): `spoke.withdrawShares` moves the shares from the `Escrow` to the receiver, and `maxMint` drops.

A redeem mirrors it (`ApproveRedeems`, `RevokeShares`, `notifyRedeem`, then `redeem`/`withdraw`). `SyncDepositVault` deposits in one call and redeems asynchronously. The `Escrow` holds both the assets and the shares; for vaults launched before v3.1.0 the ABI's `globalEscrow()` returns it.

## Branches: main vs live

- main is the library: it defines what a deployment is (contracts, schemas, tests, the deployer stack, the repo checks). Each release has its own live branch, `live-v<version>`, version-pinned and never renamed because several releases can be live at once. It holds what that release's deployment wrote and everything that acts on it.
- What is deployed: v3.2 (`live-v3.2`). v3.3, the release main's changes flow into (`live-v3.3`), is deployed nowhere yet: its configs record only `contracts.root`, the Root it keeps from v3.2. It lands as a new stack, so nothing on main has deployed state to stay compatible with or migrate. Don't propose a migration, backfill or compatibility step unless asked or working on a spell. When the v3.3 deployment's env changes land on `live-v3.3`, update this bullet in a PR to main; live cannot change this file.
- Placing a new file: if it only runs against a chain that already carries the protocol, or records what a deployment wrote, it goes on live (ops scripts, spells, the registry pipeline, fork validation, `env/testnet/` and `env/mainnet/` configs). If it defines or checks what a deployment is, it goes on main (`src/`, `ChainConfig`/`EnvConfig`, the deployer stack, `script/anvil/`, `script/checks/`). When both fit, main. The one deployment record on main is `env/spell/`, the executed-spell archive.
- Name no chain on main. A sentence naming a chain, a table keyed by network, or a per-chain quirk or workaround goes to live, even inside a file that is main's. The one exception is bytecode: `GasService`'s `MONAD_CENTRIFUGE_ID`.
- Deploying, `env/` configs, the deployer scripts, `DEPLOY_ENVIRONMENT`, CREATE3 or the DeployGate, signing with a Ledger or proposing to a Safe, reading deployed state (cast calls, storage probes, log sweeps, RPC errors), live-branch mechanics (merging main, which merge button a live PR takes, CI triggers, cutting a release), spells and Root timelocks: Read `.claude/rules/deployment.md` before answering or changing anything. It loads by itself only when you open a file it covers with the Read tool; a question that opens no file, or a read through Bash, needs the explicit Read.

## Coding Style

Contract style, structure, naming, natspec and declaration-ordering conventions live in `.claude/rules/coding-style.md`. It loads by itself when you open a `src/**` file with the Read tool, which every Edit does first; before writing a new contract, or reviewing `src/` code you have only read through Bash, Read it. What a comment may say, in any Solidity file, is `.claude/rules/comments.md`.

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
- All **admin/privileged** state-changing functions require `auth`; user-facing functions (e.g., `deposit`, `requestDeposit`, `redeem`) intentionally omit it. Some contracts gate by role instead: `Hub` has `onlyManager`/`_requireManager`, `Spoke` requires `spokeRegistry.manager(poolId, sender)` (`NotManager`), `NAVManager` checks its own per-pool `manager` mapping. `protected` is the reentrancy guard (`ReentrancyProtection`), not an access check
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

### Cross-chain addresses
- The standard CREATE3 flow gives a contract the same address on every network, but that is not a protocol invariant: some EVM chains derive addresses differently, a legacy pre-CREATE3 salt path has no cross-chain guarantee, and a non-EVM chain may have no comparable address. Never validate a remote-chain address against a local one as a security check.

### Core Patterns
- Asset resolution: `spokeRegistry.assetToId(assetAddress, tokenId)` (for a standard ERC20, `tokenId` is `0`)
- Interface casting: declare the interface type explicitly before use, and check the contract implements it:

```solidity
IBaseVault vault = IBaseVault(vaultAddress);
uint256 totalAssets = vault.totalAssets();

IERC7540Deposit asyncVault = IERC7540Deposit(vaultAddress);
uint256 pending = asyncVault.pendingDepositRequest(0, controller); // the request id is ignored

ISpokeGatewayHandler handler = ISpokeGatewayHandler(address(spokeHandler));
handler.updateRestriction(poolId, scId, update);
```

## Testing Conventions

### Structure
- **Unit tests**: fully isolated. One contract under test; mock every external dependency with `vm.mockCall`. To cast an interface onto a mock address, deploy an empty `contract IsContract {}` and mock calls on it.
- **Integration tests**: `CentrifugeIntegrationTest` (`test/integration/Integration.t.sol`, inherits `FullDeployer`) deploys the full protocol stack. Vault tests build on `VaultBaseTest`, which some files import as `BaseTest`.
- **Fork tests**: live-state tests run from the live branch, pinned to the deployed version. None on main.

### Naming
- Files are `ContractName.t.sol`, the base test is `ContractNameTest is Test`, and a function's tests group in `ContractNameTest<Function> is ContractNameTest`. Test functions start with `test` and fuzz through parameters (`testDeposit(uint256 amount)`).

### Common Patterns
- `vm.expectRevert(CustomError.selector)` before calls that should fail
- `vm.expectEmit()` + `emit EventName(...)` before calls that should emit
- Prank as the actor a call is meant to come from: `vm.prank(addr)` for one call, `vm.startPrank(addr)`/`vm.stopPrank()` for a block. `VaultBaseTest.setUp` wards the test contract on 21 contracts, Root included, so an un-pranked call passes `auth` and a negative auth test proves nothing.
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
8. **Security classes**: `.claude/prompts/` holds four review guides (async lifecycle, integration boundary, pool isolation, share custody) saying what to hunt for; Read the ones the change touches
9. **Docs drift**: Read `.claude/rules/docs-drift.md` and run its sweep over the diff; a review that reads the diff through `gh` or Bash never loads it on its own. Every claim the diff made false is a finding

## Reference Documentation

### Foundry Resources
- [Foundry Book](https://book.getfoundry.sh) - Complete Foundry documentation
- [Best Practices Guide](https://getfoundry.sh/guides/best-practices) - Coding patterns and guidelines
- [Recon Book](https://book.getrecon.xyz/writing_invariant_tests/advanced.html) - Invariant Tests guidelines

### Architecture Documentation
- `docs/architecture/`: PlantUML and SVG diagrams of contract relationships and hub-spoke interactions

### Centrifuge Protocol Documentation
- [llms.txt](https://docs.centrifuge.io/llms.txt): the index of docs.centrifuge.io. The pages it links to reject non-browser clients (403), so read the content from [llms-full.txt](https://docs.centrifuge.io/llms-full.txt), every page in one file: fetch it with `curl` and grep it, since WebFetch summarizes a file that size

### API & Indexer
- **v3 indexer, the default**: `POST https://api.centrifuge.io/`; lists are `pools(limit: n) { totalCount items { … } }`, and `{_meta{status}}` gives each chain's indexed head. Source `centrifuge/api-v3` (Ponder). Feature-frozen, so its known bugs stay: hub `holdings.assetQuantity` is wrong on some pools
- **v4 indexer, the successor, not yet at parity (2026-09-30)**: `POST https://api-v4-main.cfg.embrio.tech/graphql` (testnet `api-v4-test`); lists are `pools(first: n) { totalCount nodes { … } }`. Prefer it for hub holdings, which v3 gets wrong. Otherwise it lags v3 by hours with no head probe, does not index Arc, filters on few columns (no orders by investor), and carries negative escrow balances and phantom `IN_TRANSIT` payloads. Source `centrifuge/event-lake` and `centrifuge/backend`
- Both index events, not chain state, and share bugs such as stale `poolManagers.isBalancesheetManager` grants: confirm on chain any value a transaction will depend on
