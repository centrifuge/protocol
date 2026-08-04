# Hooks

Hooks are optional per-pool contracts that core calls out to at defined points, letting a pool add behaviour without changing core. Core holds only an interface reference and a zero address means the hook is simply skipped, so every hook here is opt-in. Two seams are covered in this module: `ISnapshotHook`, which `Holdings` fires when a network's holdings and issuance become consistent, and `IBridgingHook`, which `HubHandler` consults before a cross-chain share transfer proceeds. Transfer restrictions on the share token itself are a separate seam, documented in [`src/token/hooks`](../token/hooks).

Being hooks rather than core, these contracts are configured from the hub over the `Envoy`: each exposes `fromHub`, which accepts calls only from the `Envoy`, rejects value, and dispatches on a leading discriminant.

### `NAVManager`

`NAVManager` turns the pool's double-entry ledger into a net asset value. It sets up a pool's accounting taxonomy, giving each network its own equity, liability, gain, and loss accounts and each asset its own asset and expense accounts, with account IDs derived deterministically from the role and the asset or network. Because those IDs are derived from enum ordinals, the taxonomy is append-only: reordering would silently repoint the accounts of existing pools.

Initialization and holding configuration arrive through `fromHub` (setting the NAV hook, initializing a network, creating a holding or a liability, updating a holding's valuation), while `fromSpoke` lets a spoke-side manager reach the same operations from the chain where the assets live. On `onSync`, the hook `Holdings` fires when a network's snapshot closes, it closes out the accumulated gain and loss accounts, computes `netAssetValue` for that network from the account balances, and forwards it to the pool's `INAVHook`. `onTransfer` keeps the figures straight when shares move between networks.

### `SimplePriceManager`

`SimplePriceManager` is an `INAVHook` for single share class pools: it takes the NAV that `NAVManager` reports per network and turns it into a share price. It tracks issuance per network alongside the shares transferred in and out, so that when `ShareClassManager`'s issuance moves because of a cross-chain transfer rather than a subscription, the transferred amounts are netted out instead of being double-counted in the global issuance. Dividing the pool's total net asset value by that global issuance gives the price per share, which it pushes back to the `Hub` through `updateSharePrice`. With nothing issued yet the price falls back to 1:1. It only accepts updates from its configured `navUpdater` and rejects any share class other than the first.

### `BridgeCircuitBreaker`

`BridgeCircuitBreaker` is an `IBridgingHook` that combines a pause switch and a fixed-window rate limit, both evaluated on every cross-chain share transfer. A pause is per pool and share class; a rate limit is additionally per origin network, and the running total is tallied through the shared `ICircuitBreakerGuard`. Because the hook returns the transfer's receiver, amount, gas limit, and refund address, it sits in a position to rewrite them, but this implementation passes them through unchanged and only ever blocks.

A single transfer larger than `rateMax` can never pass the limit on its own, so it needs an explicit escape hatch. A hub manager pre-authorizes the exact transfer (pool, share class, origin, target, sender, receiver, and amount) through `AuthorizeTransfer`, which increments a counter under that key; a matching transfer then consumes one authorization and bypasses rate limiting entirely. Authorizations can be cleared again with `CancelTransferAuthorizations`.
