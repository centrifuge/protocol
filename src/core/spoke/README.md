# Spoke

The `Spoke` module manages the local state and operations for pools and share classes on each chain. It handles share token deployment, vault registration, asset tracking, cross-chain transfers, and coordinates with the `BalanceSheet` for pool-level balance management and escrow operations.

![Spoke architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/spoke.puml)

### `Spoke`

The `Spoke` contract serves as the local registry and coordination hub for all pool operations on a given chain. It manages pool and share class registration, tracks asset mappings between local addresses and global `AssetId`s, and coordinates cross-chain share transfers. The contract integrates with `TokenFactory` to deploy `ShareToken` instances, `PoolEscrowFactory` to create pool-specific escrows, and the `Gateway`'s message sender to communicate state changes to other chains.

The `Spoke` maintains price feeds for assets within each pool and share class, enabling local price lookups and validation. It handles asset registration with decimal validation and metadata extraction from ERC20 or ERC6909 tokens. For cross-chain operations, it enforces transfer restrictions via the `ShareToken`'s hook system, burns shares locally, and dispatches transfer messages to destination chains. The contract also provides request manager assignment per pool and supports untrusted contract update messages for extensibility.

### `ShareToken`

`ShareToken` is an ERC20-compliant token with ERC1404 restriction enforcement and optional transfer hook integration. Each token represents shares in a specific pool and share class, with decimals configurable per deployment. The contract integrates with an optional `ITransferHook` for custom transfer logic, restriction checks, and per-user hook data storage using a compact bytes16 format.

The token supports authorized transfers where approved managers can move tokens on behalf of users without standard ERC20 approvals. It maintains vault mappings per asset address, enabling different vaults to interact with the same share token for multi-asset pool support. Hook data can be set by either authorized contracts or the hook itself, enabling stateful transfer logic like redemption restrictions, freeze mechanisms, or identity verification.

### `BalanceSheet`

The `BalanceSheet` contract manages all balance sheet operations for pools including share issuance/revocation and asset deposits/withdrawals. It queues share and asset updates to reduce cross-chain messaging costs, allowing batched state synchronization with the `Hub`. Managers assigned per pool have authorization to execute balance sheet operations.

The contract coordinates with `PoolEscrow` for asset custody, `Spoke` for share token and asset lookups, and the `Gateway`'s message sender for cross-chain communication. It supports forced share transfers for special scenarios and integrates with an endorsements contract for additional validation. Queued updates track both issuance and revocation amounts, with separate queues per share class and asset, enabling fine-grained control over when state is synchronized across chains.

The following diagram shows how deposits and withdrawals impact the state of the balance sheet and pool escrow:

![Balance sheet diagram](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/spoke/balance-sheet.puml)

### `PoolEscrow`

`PoolEscrow` provides pool-specific asset custody separated by share class. Each escrow is tied to a single pool and holds assets across multiple share classes, tracking both total holdings and reserved amounts per asset. Reserved amounts enable pending operations like withdrawal requests to lock funds without fully removing them from the pool.

The contract exposes deposit, withdraw, reserve, and unreserve operations, all auth-protected and typically called by the `BalanceSheet`. Available balance calculations subtract reserved amounts from totals, ensuring reserved funds cannot be double-spent. The escrow extends the base `Escrow` contract with share class-level accounting and is deployed deterministically per pool by `PoolEscrowFactory`.

### `VaultRegistry`

`VaultRegistry` manages vault deployment, linking, and unlinking for pool share classes and assets. It supports three vault update kinds: deploy-and-link (using a factory), link (existing vault), and unlink (remove association). The registry tracks vault details including the associated pool, share class, asset, and request manager, enabling reverse lookups from vault address to pool context.

Vault deployment validates that async vaults have an associated request manager configured on the `Spoke`, preventing misconfigured deployments. Linking registers the vault in both forward (pool/shareClass/asset/manager → vault) and reverse (vault → details) mappings, while unlinking removes these associations and emits events for state tracking. The registry is called by the `Gateway`'s message processor when vault updates arrive from the `Hub`, ensuring vault configuration stays synchronized across chains.
