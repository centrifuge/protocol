# Hub

The `Hub` module serves as the central orchestration layer for pool management in the Centrifuge Protocol. It coordinates all core pool operations including registration, accounting, holdings management, share class configuration, and cross-chain message handling.

![Hub architecture](../../../docs/architecture/core/hub.svg)

### `Hub`

The central pool management contract that aggregates all core pool functions in a single interface. It handles pool administration including manager assignment, share class notifications, metadata updates, and asset price broadcasting across chains. Managers assigned to a pool configure holdings, update share classes, set price feeds, and coordinate cross-chain state synchronization. Their rights are bounded by the pool's policy: when one is installed, every guarded manager action is passed to it for enforcement, and out-of-policy calls have to be scheduled through `initiateAuthorization` first.

The `Hub` coordinates with `ShareClassManager`, `Holdings`, `Accounting`, and `HubRegistry` to maintain consistent pool state. It supports batched multicall operations for efficient transaction execution and integrates with an optional fee accrual hook (`IFeeAccrual`) for custom fee logic. All cross-chain communication flows through the `Hub`'s message sender (the `MessageDispatcher`), enabling pools to notify remote chains of share class updates, price changes, and other critical state transitions.

### `HubHandler`

Processes incoming cross-chain messages for the `Hub`, acting as the message receiver from the `MessageProcessor`. It handles asset registration from remote chains, inbound vault requests, asset and share amount updates, and cross-chain share transfers. All handler methods are auth-protected and called by the `MessageProcessor`, or directly by the `MessageDispatcher` when hub and spoke share a chain.

The `HubHandler` coordinates state updates across `Hub`, `Holdings`, and `ShareClassManager` based on incoming messages. It routes inbound requests to the `IHubRequestManager` registered for the pool and the chain the request came from, ensuring that vault operations flow correctly through the system. Cross-chain share transfers are passed through the pool's optional `IBridgingHook`, which may rewrite the receiver, amount, gas limit, and refund address before the shares are reissued on the destination chain. It also maintains snapshot state for cross-chain consistency, tracking when assets and shares are synchronized across different networks.

### `Holdings`

The `Holdings` contract serves as the ledger for all pool holdings, tracking assets and their associated accounting IDs. Each holding is initialized with an `IValuation` contract that determines how to price the asset in the pool's currency, along with mappings to accounting IDs for integration with the double-entry bookkeeping system.

The contract tracks holding amounts per pool, share class, and asset as cumulative increase and decrease counters, and values each delta at the holding's valuation so the value it returns to the `Hub` always mirrors the amount it just booked. A per-pool, per-network counter records how many holdings currently have decreases outrunning increases. It maintains snapshot state per chain to ensure cross-chain data consistency, tracking when the holdings on a given chain are synchronized with share issuance. Optional `ISnapshotHook` integration allows for custom logic to execute when snapshot state changes, enabling advanced pool behaviors.

### `HubRegistry`

The global registry serves as the canonical source of truth for all pools, assets, currencies, and pool-level dependencies. It handles pool registration with initial manager and currency assignment, asset registration with decimal precision tracking, and ongoing manager updates. The registry enforces uniqueness constraints, preventing duplicate pool or asset registrations and validating existence before state updates.

Beyond basic registration, `HubRegistry` manages pool metadata storage and tracks pool dependencies such as `IHubRequestManager`s per destination chain and the pool's optional `IBridgingHook`. This enables pools to configure different request handling logic for different networks while maintaining centralized visibility into pool configuration. Multiple managers can be assigned to each pool, providing flexible access control for pool operations.

The registry also holds the pool's installed policy and the authorization ledger behind it. `initiateAuthorization` schedules an out-of-policy call for the delay the policy prices, `cancelAuthorization` retires one that has not fired yet, and `consumeAuthorization` spends it once matured and not yet expired. Only the installed policy may consume, and authorization ids are namespaced by the policy address and its install nonce, so installing a policy makes every pending authorization unreachable without having to enumerate them.

### `Accounting`

A double-entry bookkeeping system that maintains financial integrity for all pool operations. Accounts are created with either debit-normal or credit-normal balances, following traditional accounting conventions. It uses a lock/unlock mechanism where a specific pool must be unlocked before journal entries can be recorded, and must be locked to commit the transaction. Locking requires that the debits and credits added while unlocked match exactly, so an unbalanced journal reverts the whole transaction. Transient storage tracks the in-flight journal state, including debited and credited amounts for the current transaction.

### `ShareClassManager`

Manages all share classes across pools and chains, handling creation, metadata, pricing, and issuance tracking. Share classes are created with unique deterministic IDs generated from the pool and an incrementing index, along with names, symbols, and salts. The contract prevents salt reuse to ensure share class uniqueness and tracks both total issuance and per-chain issuance to support cross-chain vault operations. Both are held as cumulative issued and revoked counters that only ever go up, so a revocation arriving before the issuance that minted the shares never reverts: reverting would leave the reporting chain unable to report anything further. The netted views (`totalIssuance`, `issuance`) refuse to answer while revocations exceed issuances, since the figure would be missing shares the hub has not been told about; `issuanceAcrossNetworks` and `issuancePerNetwork` expose the underlying counters and are always readable.

The manager maintains share prices (price per share in pool currency) with computed-at timestamps, validating that prices cannot be set in the future. It provides methods to update share class metadata, issue and revoke shares based on cross-chain activity, and preview the next share class ID for deterministic deployment planning. Share issuance is tracked separately per chain to enable accurate accounting when shares are minted or burned on different networks.
