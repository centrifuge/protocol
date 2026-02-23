# Spell 006: V3.0.1 to V3.1 Full Protocol Migration

## Overview

| Field             | Value                                                  |
| ----------------- | ------------------------------------------------------ |
| **Spell Address** | `0xe97ac43A22B8Df15D53503cf8001F12c6B349327`           |
| **Deployment**    | CREATE3 deterministic (same address on all chains)     |
| **Description**   | Full protocol redeployment with atomic state migration |
| **Source Branch** | `main`                                                 |

## Networks

| Network         | Chain ID  | centrifugeId |
| --------------- | --------- | ------------ |
| Ethereum        | 1         | 1            |
| Base            | 8453      | 2            |
| Arbitrum        | 42161     | 3            |
| Avalanche       | 43114     | 5            |
| BNB Smart Chain | 56        | 7            |
| Plume           | 161221135 | 6            |

## How This Differs from Spells 001-005

Previous spells were targeted contract updates with hardcoded per-network constants and a single `cast()` entry point. This migration:

- **Redeployed the entire v3.1 protocol** alongside existing v3.0.1 contracts
- Used **dynamic parameters** queried from the Centrifuge GraphQL API at execution time (no hardcoded per-network values)
- Has a **multi-phase execution model**: `castGlobal()` once, then `castPool()` per pool, then `lock()`
- **Identical bytecode** on all chains (same code, same address via CREATE3)

## Execution Flow

```
1. Deploy fresh v3.1 contracts (via FullDeployer)
2. Root.rely(migrationSpell)          -- grant spell permissions
3. migrationSpell.castGlobal(input)   -- migrate global state (assets, vaults, gateway funds, permissions)
4. for each pool:
     migrationSpell.castPool(poolId, input)  -- migrate pool-specific state
5. migrationSpell.lock(root)          -- revoke spell permissions, set owner to address(0)
```

The executor script that orchestrated this flow is `script/spell/MigrationV3_1.s.sol`.

## Dynamic Parameters

All migration parameters were queried at execution time from the Centrifuge GraphQL API. The query definitions are in `script/spell/MigrationQueries.sol` and include:

- `v3Contracts()` - All v3.0.1 deployed contract addresses
- `pools()` - All pools across all chains
- `spokeAssetIds()` / `hubAssetIds()` - Asset registrations
- `vaults()` - All vault addresses
- `assets()` - Asset info (address + tokenId)
- `bsManagers(poolId)` - Balance sheet managers per pool
- `hubManagers(poolId)` - Hub managers per pool
- `onOfframpManagerV3(poolId)` - OnOfframp manager per pool
- `onOfframpReceivers(poolId)` / `onOfframpRelayers(poolId)` - Offramp configurations
- `chainsWherePoolIsNotified(poolId)` - Cross-chain pool destinations

## Migrated State

### Global (`castGlobal`)

- **Asset registrations**: Spoke assets re-registered on new Spoke; Hub assets re-registered on new HubRegistry
- **Vault manager assignments**: All vaults pointed to new AsyncRequestManager and SyncManager (deny old, rely new)
- **Root permissions**: Rely new ProtocolGuardian, TokenRecoverer, MessageDispatcher, MessageProcessor; deny v3.0.1 equivalents
- **Root endorsements**: Endorse new BalanceSheet, AsyncRequestManager, VaultRouter
- **Gateway subsidized funds**: Recovered from v3.0.1 Gateway to executor
- **GlobalEscrow sweep**: All ERC20 balances (excluding share tokens) transferred from v3.0.1 GlobalEscrow to executor

### Per-Pool (`castPool`)

- **MultiAdapter**: Pool-specific adapter configurations copied from GLOBAL_POOL settings
- **HubRegistry**: Pool registration, managers, metadata, hub request manager assignments
- **ShareClassManager**: Share class metadata, NAV prices, per-chain issuance
- **BatchRequestManager**: Epoch IDs (deposit/redeem/issue/revoke) per share class per asset
- **Spoke**: Pool activation, request manager, share token linking, share/asset prices and max ages
- **BalanceSheet**: Manager permissions (remapping v3.0.1 managers to v3.1 equivalents)
- **PoolEscrow**: Asset and share token balances transferred from v3.0.1 escrow to v3.1 escrow, including holding state (total + reserved)
- **ShareToken**: Ward permissions (rely new Spoke/BalanceSheet, deny old), hook migration (FreezeOnly, FullRestrictions, FreelyTransferable, RedemptionRestrictions)
- **VaultRegistry**: Vault registrations and linked status
- **SyncManager**: Valuation addresses and maxReserve settings
- **OnOfframpManager**: New manager deployed per pool, onramp/offramp/relayer configurations migrated via ContractUpdater trusted calls
- **Subsidized funds**: Per-pool Gateway subsidies and PoolEscrow ETH balances recovered to refund address

## Defensive Patterns

The spell uses try-catch extensively to prevent malicious or misbehaving assets from blocking the migration:
- `balanceOf` calls wrapped in try-catch
- `authTransferTo` calls wrapped in try-catch
- Share token hooks temporarily removed during transfer, then restored
- `supportsInterface` checks for share token detection wrapped in try-catch

## Validation

The migration was validated using a comprehensive fork test suite with 20+ validators covering all migrated state categories. The test and validation infrastructure can be found on the `spell-006_v3.1.0` tag under `test/spell/migration/`.
