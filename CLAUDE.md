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
│   │   ├── Spoke.sol       # Simplified spoke logic
│   │   ├── VaultRegistry.sol # Vault registration
│   │   ├── BalanceSheet.sol # Balance tracking
│   │   ├── ShareToken.sol  # ERC20 share tokens
│   │   ├── PoolEscrow.sol  # Pool-specific escrow
│   │   ├── factories/      # Token & escrow factories
│   │   └── interfaces/
│   ├── messaging/          # Message infrastructure
│   │   ├── Gateway.sol     # Cross-chain message routing
│   │   ├── MultiAdapter.sol # Multi-protocol messaging
│   │   ├── MessageProcessor.sol # Process messages
│   │   ├── MessageDispatcher.sol # Dispatch messages
│   │   ├── GasService.sol  # Gas management
│   │   └── libraries/
│   │       └── MessageLib.sol
│   ├── libraries/
│   │   └── PricingLib.sol  # Pricing calculations
│   └── utils/
│       ├── BatchedMulticall.sol
│       └── ContractUpdater.sol # Contract update handler
├── admin/                  # Admin & governance
│   ├── Root.sol           # Root authority
│   ├── OpsGuardian.sol    # Operational guardian
│   ├── ProtocolGuardian.sol # Protocol guardian
│   ├── TokenRecoverer.sol # Token recovery
│   └── interfaces/
├── managers/              # Automation managers
│   ├── hub/
│   │   ├── NAVManager.sol # NAV automation
│   │   └── SimplePriceManager.sol # Price automation
│   └── spoke/
│       ├── QueueManager.sol # Queue automation
│       ├── OnOfframpManager.sol # On/off ramp
│       └── MerkleProofManager.sol # Merkle proofs
├── vaults/                # Vault implementations
│   ├── BatchRequestManager.sol # Batch request handling
│   ├── AsyncRequestManager.sol # Async requests
│   ├── AsyncVault.sol     # ERC-7540 async vault
│   ├── SyncDepositVault.sol # Sync deposits
│   ├── SyncManager.sol    # Sync operations
│   ├── VaultRouter.sol    # Vault routing
│   ├── BaseVaults.sol     # Base implementations
│   └── factories/
├── hooks/                 # Transfer restrictions
│   ├── BaseTransferHook.sol # Base hook logic
│   ├── FreelyTransferable.sol
│   ├── FreezeOnly.sol
│   ├── FullRestrictions.sol
│   └── RedemptionRestrictions.sol
├── valuations/            # Asset valuations
│   ├── OracleValuation.sol # Oracle-based pricing
│   └── IdentityValuation.sol
├── adapters/              # Cross-chain adapters
│   ├── AxelarAdapter.sol
│   ├── ChainlinkAdapter.sol
│   ├── LayerZeroAdapter.sol
│   ├── RecoveryAdapter.sol
│   └── WormholeAdapter.sol
├── utils/                  # Utilities
│   ├── RefundEscrow.sol   # Refund handling
│   ├── RefundEscrowFactory.sol
│   └── SubsidyManager.sol
├── spell/                  # Governance spells
│   └── V2CleaningsSpell.sol
└── misc/                  # Utilities & types
    ├── Auth.sol          # Auth mixin
    ├── ERC20.sol         # Token standard
    ├── Escrow.sol        # Escrow logic
    ├── types/            # Custom types
    ├── libraries/        # Utility libraries
    └── interfaces/       # Standard interfaces

test/                        # Tests mirror src/ structure
├── core/                 # Hub & spoke tests (unit + integration)
├── vaults/               # Vault tests (unit + integration)
├── managers/             # Manager contract tests
├── hooks/                # Transfer hook tests
├── adapters/             # Cross-chain adapter tests
├── integration/          # Cross-module integration & fork tests & spell tests
└── misc/                 # Utility & library tests

script/
├── deploy/              # Deployment scripts
├── spell/               # Spell execution scripts
└── utils/               # Helper scripts

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
- **Phase 2a: APPROVE** (`batchRequestManager.approveDeposits → balanceSheet.noteDeposit`)
  - Admin approves pending deposits
  - `balanceSheet.noteDeposit()` calls `escrow(poolId).deposit()` to account for assets
  - `balanceSheet.issue()` mints shares to PoolEscrow address
  - State: PoolEscrow ✅ assets accounted, shares minted to PoolEscrow

- **Phase 2b: NOTIFY** (`batchRequestManager.notifyDeposit`)
  - Notifies users deposits are ready to claim
  - Updates `AsyncRequestManager.maxMint` allocations
  - State: PoolEscrow ❌ NO CHANGE | maxMint ✅ UPDATED

**Phase 3: CLAIM** (`vault.deposit/mint`)
- User claims allocated shares
- Shares transfer from PoolEscrow to user via `balanceSheet.withdraw()`
- `AsyncRequestManager.maxMint` decreases (allocation consumed)
- State: PoolEscrow ✅ shares decrease | User balance ✅

**Async Redeem:** Analogous flow in reverse (`requestRedeem` → `approveRedeems`/`notifyRedeem` → `redeem/withdraw`), where user sends shares and receives assets.

**Sync Vaults:** All phases execute atomically in single call.

**Key Insight:** PoolEscrow holds both assets and shares. Assets are accounted during APPROVAL (Phase 2a), shares are claimed during CLAIM (Phase 3).

## Deployment Info
- **Current Version**: v3.1.0 (see `env/*.json` for network-specific details)
- Contract addresses are deterministic across ALL networks (CREATE3)
- Find addresses in `env/*.json` (e.g., `env/ethereum.json`)

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

## Critical Coding Rules

### Language & Compilation
- Solidity 0.8.28, Cancun EVM
- Refactor "Stack too deep" errors instead of enabling `via_ir`, because `via_ir` changes compilation behavior and can mask real complexity issues
- Use custom errors only: `error NotAuthorized();` (more gas efficient than string reverts)
- Prefix interfaces with `I` (e.g., `IVault`, `ISpoke`)

### Access Control (Ward Pattern)

⚠️ **Primary Security Boundary** - The Ward pattern is the main access control mechanism. Missing `auth` modifiers are the most common security vulnerability.

```solidity
modifier auth() { require(wards[msg.sender] == 1, NotAuthorized()); _; }
```
- All **admin/privileged** state-changing functions require `auth` — user-facing functions (e.g., `deposit`, `requestDeposit`, `redeem`) intentionally omit it. Some contracts use role-specific modifiers instead (e.g., `isManager(poolId)` on BalanceSheet, `onlyManager` on NAVManager)
- Every `rely()` needs matching `deny()`, since orphaned permissions accumulate and create attack vectors
- Permission hierarchy flows from Root → All contracts

### Type System

Use custom types to prevent cross-pool operations that could route funds incorrectly:
```solidity
type PoolId is uint64;
type AssetId is uint128;
type ShareClassId is uint64;
```
- Use custom types for all IDs (raw uints bypass the type system's protection)
- Use `CastLib.toBytes32(address)` for address→bytes32 conversion (the manual `bytes32(uint256(uint160(controller)))` pattern is error-prone)

### Core Patterns
- Follow CEI (Checks-Effects-Interactions) pattern to prevent reentrancy in vault operations
- Asset resolution: Use `spoke.assetToId(assetAddress, tokenId)` for consistent ID lookup (for standard ERC20 assets, `tokenId` is `0`)
- Interface casting: Declare interface type explicitly before use for clarity

## Common Patterns & Anti-Patterns

### Interface Resolution Patterns
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
- Always verify interface compatibility before calling
- Prefer avoiding try-catch in tests; if possible, use `vm.expectRevert` instead for clearer failure assertions

### State Validation
```solidity
// Always check contract states before operations
require(spoke.isPoolActive(poolId), "Pool not active");
require(IAuth(address(spoke)).wards(address(this)) == 1, "No permission");
```

### Storage Anti-Patterns
**Problem**: Constants or storage variables in base contracts unused by all children
**Solution**: Move to specific derived contracts that actually use them
**Rule**: If only one child contract uses a constant, declare it there, not in the shared base

### Inheritance Best Practices

Use `super.execute()` to reuse parent logic, because duplicating code leads to inconsistencies when the parent changes:
```solidity
// Recommended: Extend parent logic
function execute() public override {
    super.execute();
    // Add child-specific logic
}

// Avoid: Duplicating parent logic creates maintenance burden
function execute() public override {
    // Copy-pasted parent logic (will diverge over time)
    // Child logic
}
```

### Stack Too Deep Solutions

When a function exceeds 16 local variable slots, refactor using these techniques (in order of preference):
1. **Group parameters into structs** - Reduces stack slots and improves readability
2. **Extract helper functions** - Split complex calculations into smaller functions
3. **Use storage/memory efficiently** - Minimize local variables by reading directly
4. **Refactor instead of using `via_ir`** - The `via_ir` flag masks complexity issues

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

## Code Quality Checklist

### Code Review & Cleanup
- **Storage**: Remove redundant variables, unused constants, unnecessary initializations
- **Inheritance**: Use `super.execute()` instead of duplicating parent logic
- **Interfaces**: Ensure consistent asset ID resolution (`spoke.assetToId`)
- **Gas**: Optimize storage layout, remove redundant operations
- **Compiler**: Fix all warnings (unused params, state mutability, unreachable code)

### Critical Review Points (Priority Order)

1. **Access Control** (highest priority): Ward pattern implementation on all admin/privileged state-changing functions
2. **CEI Compliance**: Checks→Effects→Interactions order to prevent reentrancy
3. **State Validation**: Check assumptions before operations (e.g., pool exists, sufficient balance)
4. **Custom Types**: Use PoolId, AssetId, ShareClassId instead of raw uints
5. **Cross-chain**: Verify deployment consistency across networks
6. **Integration**: Manager contracts and hook implementations
7. **Custom Errors**: Descriptive and properly used

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
