# Vaults

The vaults module implements ERC-4626 and ERC-7540 tokenized vault standards for Centrifuge pools, providing both synchronous and asynchronous deposit/redeem workflows. It includes vault implementations, request managers for handling epoch-based operations, and routing infrastructure for simplified user interactions.

![Vaults architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/vaults/vaults.puml)

### `AsyncVault`

`AsyncVault` implements the ERC-7540 asynchronous tokenized vault standard, extending ERC-4626 with request-based deposit and redeem workflows. Users submit deposit and redeem requests that are queued for execution in the next epoch. After epoch execution, users can claim their shares or assets using standard ERC-4626 methods. The vault integrates with `AsyncRequestManager` for request handling and supports ERC-7887 cancellation flows.

The vault enforces controller/owner validation for all operations and integrates with the global escrow for asset custody during pending requests. It tracks pending and claimable amounts per controller, enabling users to monitor their request status. The vault supports operator endorsements, allowing approved addresses to act on behalf of users for deposits and redemptions.

### `SyncDepositVault`

`SyncDepositVault` provides a hybrid model with synchronous deposits (immediate share issuance) and asynchronous redemptions (epoch-based). It implements ERC-4626 for deposits and ERC-7540 for redemptions, offering the best of both models. Deposits execute immediately at the current share price via `SyncManager`, while redemptions follow the async request-fulfill-claim pattern via `AsyncRedeemManager`.

This vault type is ideal for pools that want to enable instant deposits while maintaining controlled, epoch-based redemptions for liquidity management. It integrates with both `SyncDepositManager` and `AsyncRedeemManager`, requiring separate manager configurations for each operation type.

### `BatchRequestManager`

`BatchRequestManager` handles epoch-based deposit and redeem requests on the Hub side, managing request aggregation, epoch execution, and fulfillment coordination. It tracks pending requests per pool, share class, and asset, aggregating them into epochs that can be approved or rejected. The manager maintains user order state, queued orders for cancellations, and epoch execution history.

The contract implements `IHubRequestManager` and receives request callbacks from spoke chains via the `Hub`. It supports force cancellation flows with safeguards, requiring explicit permission before allowing managers to cancel user requests. Epoch management tracks invest and redeem amounts separately, with fulfillment calculations based on approved amounts and share prices. The manager integrates with `Hub` for accounting updates and cross-chain communication back to spoke vaults.

### `AsyncRequestManager`

`AsyncRequestManager` is the primary spoke-side contract that vaults interact with for deposit and redeem request handling. It manages request submission, cancellation, and claim workflows, coordinating with `BalanceSheet` for share issuance/burning and the global escrow for asset custody. The manager tracks per-vault, per-investor state including pending requests, claimable amounts, and cancellation status.

The contract handles cross-chain request callbacks from the Hub, processing approvals, rejections, and cancellation confirmations. It manages refund escrows per pool for subsidizing gas for cross-chain transactions. The manager supports both deposit and redeem flows, validating request transitions and ensuring users can only claim what's been approved by the Hub.

The following diagram shows how funds flow in and out of the escrow:

![Flow of funds](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/vaults/flow-of-funds.puml)

### `SyncManager`

`SyncManager` enables synchronous ERC-4626 deposits by coordinating immediate share issuance based on current valuations. It integrates with pool-specific `ISyncDepositValuation` contracts to determine share prices and validates reserve limits to prevent over-issuance. The manager coordinates with `BalanceSheet` for share minting and asset deposits.

The contract supports trusted contract updates for configuring valuation contracts and max reserve limits per pool, share class, and asset. It implements deposit and mint operations, calculating share amounts from assets and vice versa based on the configured valuation. Reserve limits protect pools from excessive deposits when liquidity is constrained.

### `VaultRouter`

`VaultRouter` serves as a user-friendly entrypoint for EOA interactions with vaults, simplifying the multi-step processes required for deposits, redemptions, and claims. It provides convenience methods that handle token approvals, request submissions, and batch operations in single transactions. The router integrates with `Spoke`, `VaultRegistry`, and a router-specific escrow for temporary asset custody.

The contract supports permit-based approvals (ERC-2612) to reduce transaction overhead, locked request tracking to prevent double-spending during multi-step operations, and multicall batching for complex workflows. It's critical that no funds remain in the router after transactions, as any leftover funds could be claimed by other users. The router manages operator endorsements, allowing users to authorize it to act on their behalf for vault operations.

### `RefundEscrow`

`RefundEscrow` holds ETH subsidies per pool to pay the cost of cross-chain messages for users. Pools can deposit subsidies that are used to pay for requests requiring cross-chain communication. The escrow tracks balances per pool and provides withdrawal functions for pool managers.