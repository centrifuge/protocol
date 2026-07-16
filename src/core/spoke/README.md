# Spoke

The `Spoke` module manages the local state and operations for pools and share classes on each chain. It handles share token deployment, vault registration, asset tracking, cross-chain transfers, and pool-level balance-sheet management (share issuance/revocation, asset deposits/withdrawals) and escrow operations. This mirrors the Hub architecture: `Spoke` ↔ `Hub`, `SpokeHandler` ↔ `HubHandler`, `SpokeRegistry` ↔ `HubRegistry`, and `SnapshotQueue` ↔ `Holdings`.

![Spoke architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/spoke.puml)

### `Spoke`

The `Spoke` contract is the coordination hub for pool operations on a given chain: cross-chain share transfers, asset registration, request forwarding, manager calls, and all balance-sheet operations (share issuance/revocation, asset deposits/withdrawals, reserves, and forced share transfers). It is a `BatchedMulticall`, so operations can be batched into a single cross-chain payload. Pool and share class registration, asset mappings between local addresses and global `AssetId`s, prices, manifest policies, manager roles, and vault state live in `SpokeRegistry`, while inbound cross-chain messages are handled by `SpokeHandler`. It uses the `Gateway`'s message sender to communicate state changes to other chains.

The `Spoke` handles asset registration with decimal validation and metadata extraction from ERC20 or ERC6909 tokens. For cross-chain operations, it enforces transfer restrictions via the `ShareToken`'s hook system, burns shares locally, and dispatches transfer messages to destination chains. It forwards investment requests to the pool's request manager and routes manager calls to their targets. Balance-sheet operations coordinate with `PoolEscrow` for asset custody and queue share and asset deltas in `SnapshotQueue` to reduce cross-chain messaging costs, allowing batched state synchronization with the `Hub`. A single per-pool `manager` role, stored in `SpokeRegistry`, gates both holding initialization and balance-sheet operations; the latter are additionally policed by the pool's manifest when one is installed.

### `ShareToken`

`ShareToken` is an ERC20-compliant token with ERC1404 restriction enforcement and optional transfer hook integration. Each token represents shares in a specific pool and share class, with decimals configurable per deployment. The contract integrates with an optional `ITransferHook` for custom transfer logic, restriction checks, and per-user hook data storage using a compact bytes16 format.

The token supports authorized transfers where approved managers can move tokens on behalf of users without standard ERC20 approvals. It maintains vault mappings per asset address, enabling different vaults to interact with the same share token for multi-asset pool support. Hook data can be set by either authorized contracts or the hook itself, enabling stateful transfer logic like redemption restrictions, freeze mechanisms, or identity verification.

### `SnapshotQueue`

The `SnapshotQueue` contract is an `auth`-gated store of the queued share and asset deltas each pool accumulates before they are submitted to the `Hub`, analogous to how `Holdings` backs the `Hub`. `Spoke` is its only ward. Share deltas are netted per share class (issuance adds, revocation subtracts); asset flows are accumulated gross per asset. Flushing consumes a queue and returns the update payload (net amount, snapshot flag, nonce) that `Spoke` sends to the `Hub`, reducing cross-chain messaging costs by batching state synchronization.

The following diagram shows how deposits and withdrawals impact the state of the balance sheet and pool escrow:

![Balance sheet diagram](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/spoke/balance-sheet.puml)

### `PoolEscrow`

`PoolEscrow` provides pool-specific asset custody separated by share class. Each escrow is tied to a single pool and holds assets across multiple share classes, tracking both total holdings and reserved amounts per asset. Reserved amounts enable pending operations like withdrawal requests to lock funds without fully removing them from the pool.

The contract exposes deposit, withdraw, reserve, and unreserve operations, all auth-protected and typically called by the `Spoke`. Available balance calculations subtract reserved amounts from totals, ensuring reserved funds cannot be double-spent. The escrow extends the base `Escrow` contract with share class-level accounting and is deployed deterministically per pool by `PoolEscrowFactory`.

### `SpokeRegistry`

`SpokeRegistry` is the on-chain registry for the spoke. It tracks pool and share class registration, asset mappings between local addresses and global `AssetId`s, the per-pool request manager, and prices per share class and asset. It also manages vault deployment, linking, and unlinking across three update kinds: deploy-and-link (using a factory), link (existing vault), and unlink (remove association), tracking vault details including the associated pool, share class, asset, and request manager for reverse lookups from a vault address to its pool context.

Vault deployment validates that async vaults have an associated request manager configured on the `Spoke`, preventing misconfigured deployments. Linking registers the vault in both forward (pool/shareClass/asset/manager → vault) and reverse (vault → details) mappings, while unlinking removes these associations and emits events for state tracking. The registry is called by the `Gateway`'s message processor when vault updates arrive from the `Hub`, ensuring vault configuration stays synchronized across chains.
