# Core

The `core` module is the protocol's immutable core: the minimal set of contracts required to register pools, account for holdings, manage share classes, and move state between chains. Once deployed, none of it can be upgraded or altered, so builders compose on top of a security surface that does not shift under them.

Everything else in the protocol (vault implementations, managers, hooks, valuations, adapters) is a modular extension that plugs into `core` without requiring changes to it. A manager keeps full control over product decisions (which assets, who may hold them, how they price, how settlement is timed) while the shared accounting, settlement, and messaging machinery stays unchanging underneath.

A pool is one balance sheet, kept consolidated across every chain it operates on, even though no single chain holds the whole picture. `core` is organized around three sub-modules that make that possible: `hub` runs the pool's control plane on one chain of the operator's choosing, holding the books and authority but never custodying user assets; `spoke` is the pool's local presence on every chain it operates on, issuing shares and custodying assets in segregated, pool-scoped escrows; and `messaging` carries state between the two.

`messaging` abstracts cross-chain routing and transport security away from `hub` and `spoke`. That boundary is secured by verifying every message against a configurable quorum of independent `adapters`, made cost-efficient through nestable batching that folds a whole cascade of operations into one payload per destination and pool, and paid for onchain so cross-chain execution fees are settled as part of dispatch rather than tracked out of band.

### [`hub`](./hub)

The central orchestration layer for pool management. `Hub` aggregates pool administration: manager assignment, share class notifications, metadata updates, and price broadcasting to every spoke a pool operates on.

`Holdings` is the canonical ledger of everything a pool owns or owes, wiring each holding to a pluggable valuation and to the accounts that back it. `Accounting` is the double-entry engine underneath, recording every value change as a balanced journal entry (debits and credits scoped per pool, per account) and reverting the whole transaction rather than ever letting the books go unbalanced.

`ShareClassManager` handles share class creation, metadata, pricing, and per-chain issuance tracking. `HubRegistry` is the canonical source of truth for pools, assets, currencies, and pool-level dependencies such as request managers, including the pool's policy: an onchain contract a pool installs to bound what its managers may do, which `HubRegistry` holds as the pool's authoritative reference and `Hub` checks before executing any guarded manager action.

Because `Hub` consolidates all of this in one place, a manager acting on any pool reasons about a single, always-balanced set of books rather than reconciling state scattered across chains. See [`hub/README.md`](./hub/README.md).

### [`spoke`](./spoke)

The local counterpart to `hub`, deployed on every chain a pool operates on. `Spoke` mirrors `Hub`'s role for local operations: asset registration, cross-chain share transfers, request forwarding, and balance-sheet management (share issuance/revocation, asset deposits/withdrawals), with share token deployment and vault registration arriving from the hub through `SpokeHandler`, all backed by `SpokeRegistry`, `PoolEscrow`, and `SnapshotQueue`. The two sides deliberately mirror each other: `Spoke` ↔ `Hub`, `SpokeHandler` ↔ `HubHandler`, `SpokeRegistry` ↔ `HubRegistry`, `SnapshotQueue` ↔ `Holdings`.

`PoolEscrow` custodies assets per pool and per share class rather than pooling them together. `SnapshotQueue` nets share deltas and accumulates asset deltas locally before flushing a single update to `Hub`, so routine activity on a chain does not have to cross a chain boundary for every deposit or withdrawal.

Because a spoke is a complete local deployment, everything it does executes synchronously and atomically: issuing a share, moving an asset, and a call into another protocol can happen in one transaction that either wholly succeeds or wholly reverts. This is what lets share tokens compose with the rest of onchain finance without a settlement gap.

`Spoke` extends the same policy-bound guard to its own manager actions, checking the spoke-side policy the hub installed in `SpokeRegistry` before letting a manager through, so a manager's rights stay policy-bound on every chain a pool touches rather than only at the hub. See [`spoke/README.md`](./spoke/README.md).

### [`messaging`](./messaging)

The cross-chain transport layer connecting `hub` and `spoke`. `MessageDispatcher` serializes and routes outgoing messages, short-circuiting to a direct call for same-chain destinations. `MessageProcessor` deserializes and routes incoming messages to the right handler.

`Gateway` batches everything bound for one destination and pool into a single payload and settles cross-chain execution fees onchain as part of dispatch. `MultiAdapter` fans that payload out across one or more configured `adapters` and only forwards it for execution once a configurable quorum of them agrees on the identical payload, so no single adapter can forge a message on its own. See [`messaging/README.md`](./messaging/README.md).

### Integration points

Both `hub` and `spoke` expose a set of pool-scoped extension points that periphery modules plug into, rather than requiring any change to `core` itself.

`hub`:
- **Hub manager** - the per-pool role allowed to call guarded `Hub` actions.
- **Policy** (`IHubPolicy`) - onchain contract a pool installs to bound and timelock what its managers may do.
- **Snapshot hook** (`ISnapshotHook`) - optional callback on `Holdings` when a chain's snapshot state changes.
- **Bridging hook** (`IBridgingHook`) - optional per-pool hook `HubHandler` invokes around cross-chain share transfers.
- **Valuation** (`IValuation`) - pluggable per-holding pricing model.
- **Request manager** (`IHubRequestManager`) - pluggable per-pool-per-chain settlement contract for deposit/redeem requests.
- **`managerCall` / Envoy** (`IManagerCallFromHub`) - generic, policy-gated escape hatch to call any contract implementing `fromHub`.

`spoke`:
- **Spoke manager** - the per-pool role allowed to call guarded balance-sheet actions.
- **Policy** (`ISpokePolicy`) - the spoke-side counterpart, installed by the hub and enforced locally by `Spoke` on every chain a pool touches; authorizations arrive already matured, so it keeps no timelock of its own.
- **Registrar** (`IRegistrar`) - pluggable per-share-class contract that deploys and operates the share token.
- **Bridger** - the per-pool role an owner must hold for their shares to be transferred across chains.
- **Request manager** (`ISpokeRequestManager`) - the spoke-side counterpart to the hub's request manager; the only caller allowed to dispatch outbound requests.
- **`managerCall` / Envoy** (`IManagerCallFromSpoke`) - permissionless escape hatch to call any contract implementing `fromSpoke`, which validates the caller itself.

### Supporting code

- **[`types`](./types)** - Custom value types (`PoolId`, `ShareClassId`, `AssetId`, `AccountId`, `RequestId`) used throughout `core` instead of raw `uint`/`bytes` to prevent cross-pool or cross-asset mix-ups.
- **[`utils`](./utils)** - Shared primitives used by both `hub` and `spoke`: `BatchedMulticall` for batching calls into a single transaction, `Envoy` as the stable `msg.sender` anchor for manager calls, and the `IPolicy` interfaces both enforcement guards are written against.
- **[`libraries`](./libraries)** - `PricingLib`, shared pricing conversion math used across `hub` and `spoke`.
