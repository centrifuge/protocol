# Protocol specification

This is the behavioral specification of the Centrifuge Protocol. Each row states a property the
protocol is designed to uphold, at the granularity a reader can check against the contracts.
Together the rows define what the protocol guarantees, what it deliberately does not, and where each
guarantee is mechanically enforced.

Read it as normative. If the code and a `y` row disagree, that is a bug in one of the two, and the
disagreement should be resolved rather than documented. Rows marked `n` are equally normative: they
record properties a reader might reasonably expect that the protocol does **not** promise, so that
integrators and reviewers can see the boundary of the guarantee rather than infer it.

Scope is `src/core`, `src/vaults`, and `src/token`, plus the compositional properties that no single
contract enforces alone. Adapters, managers, hooks, valuations, and admin contracts are out of scope
for now.

## How to read a row

* **Invariant**: the property, stated so it can be checked. One property per row.
* **Holds**: `y` if the protocol upholds it on the current contracts. `n` if it deliberately does not
  (intended behavior, confirmed with a maintainer) or is a known, acknowledged break. Every `n`
  carries its rationale in Notes; treat them as documented non-guarantees, not defects.
* **FV**: where the property is formally verified (Certora specs in `certora/`). `main` if merged,
  `#278` if added in
  [protocol-internal#278](https://github.com/centrifuge/protocol-internal/pull/278), `-` if nowhere.
  An FV entry reflects the Certora AutoProver (automated batch prover) run on the listed contracts;
  specs are CVL-typechecked in CI, but SMT re-proving needs the Certora cloud and is not re-run per
  commit.
* **Fuzz**: where the property is checked under fuzzing, naming what checks it. `e2e` is the
  protocol-wide Chimera suite in `test/integration/recon-end-to-end`, run by Foundry
  (`CryticToFoundry`, in PR CI) and by Echidna and Medusa (`CryticE2ETester`): a `property_*` or
  `doomsday_*` name is a standing check, any other name a handler asserting the property inline right
  after its action. `#266` is the standalone `test/integration/recon-messaging` suite added in
  [protocol-internal#266](https://github.com/centrifuge/protocol-internal/pull/266), `unit` a Foundry
  fuzz test named in Notes, and `-` nowhere.
* **Notes**: why a property doesn't hold, or why it does when that isn't self-evident.

A property with `-` in both FV and Fuzz is still part of the specification; it is simply unverified
today, and is a candidate for a future spec or fuzz property. The coverage columns are maintained by
hand, so confirm against the test suite before treating a `-` as a work item.

## Vocabulary

A **manifest** is an optional per-pool policy contract (installed in HubRegistry/SpokeRegistry) that
gates manager calls and timelocked authorizations; "manifest authority" means a call passed the
installed manifest's checks. **Unpaid mode** is the Gateway flag that lets a message be sent with
payment deferred to a later `repay`. Each acknowledged break carries its rationale inline in the
Notes column of its own row.

## Contents

* [System-level properties](#system-level-properties): compositional, spanning modules
* [Core specification](#core-specification): `src/core`
* [Vaults specification](#vaults-specification): `src/vaults`
* [Token specification](#token-specification): `src/token`

## System-level properties

Compositional properties that span hub, spoke, messaging, vaults, and token: no single contract
enforces them alone.

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| No operation creates or destroys shares globally: hub total issuance equals the sum of per-network nets | y | #278 | - | The ShareClassManager ledger identity |
| A cross-chain share transfer decreases origin-network issuance and increases target-network issuance by exactly the same amount in one transaction | y | - | - | Composes `HubHandler.initiateTransferShares` with the spoke's burn-before-message |
| On every network, share token `totalSupply` equals the sum of all holder balances (investors + escrows) | y | - | e2e `property_sum_of_balances`, `property_shareTokenSupplyConsistency`, `property_shareTokenCountedInSupply` | Checked on all three pools of the suite, including the one only reached through another pool's liquidity route |
| Hub/spoke holdings conservation: once snapshot queues are drained and messages delivered, hub `holdings.amount` equals the escrow's accounted balance (`total - reserved`, floored at zero) per `(pool, scId, asset)` | y | - | e2e `property_hubHoldingMatchesEscrowAccounted`, `balanceSheet_submitQueuedAssets` | Holds exactly, even during transient periods where reservations exceed the escrow total (over-reservation, see the Escrow section) and the accounted balance sits at the zero floor |
| Escrow backing (holdings): each escrow's raw token balance covers the sum of accounted holding totals | y | - | e2e `property_escrowBalanceMatchesHoldingTotal` | Asserted as equality, per escrow and holding asset |
| Escrow backing (entitlements): all user-claimable entitlements (assets and shares) are covered by escrow balances | y | - | e2e `property_sum_of_possible_account_balances_leq_escrow` | Claimable payouts against each vault's redeem reservation, claimable and pending-redeem shares against the escrow's share balance. The suite runs the aliasing topology (a pool holding another pool's share token) but asserts entitlements on the holding pool only |
| Escrow leak resistance: no accounted asset leaves an escrow without an equal ledger decrement in the same call | y | - | - | The only token-exit paths are `authTransferTo` and `recoverTokens`, both ward-gated. Both accounted-asset call sites (`Spoke.withdraw`, `Spoke.withdrawReserved`) pair the transfer 1:1 with `escrow.withdraw`; `Spoke.withdrawShares` moves the share token, which is not asset-accounted; `recoverTokens` is unpaired by design and has no `src/` caller. The converse does not hold: `noteDeposit` credits the ledger with no inflow, so `balance - total` is not monotone and may go negative (see the Spoke section) |
| Value-outflow soundness: cumulative shares/assets paid out to investors never exceed what managers fulfilled and approved, per request and cumulatively | y | - | e2e `property_sum_of_shares_received`, `property_sum_of_assets_received`, `property_cancelled_and_processed_deposits_soundness`, `property_cancelled_and_processed_redemptions_soundness` | Also inline in every claim handler: no claim pays out more than the controller's max |
| Authorization completeness: every gated state change requires the appropriate ward, manager, or manifest authority; successful privileged calls are made only by authorized accounts and authorization changes are tracked exactly | y | - | e2e `property_authorizationBypass`, `property_authorizationLevel`, `property_authorizationChange` | Fuzzed over the spoke's balance-sheet operations, each made by the manager, by a manager whose role the fuzzer grants and revokes through the hub, or by an outsider; per-contract access control is additionally FV'd contract by contract |
| Exactly-once message effect: an inbound message executes only behind an adapter quorum, and weighted executions never exceed deliveries across sessions | y | - | #266 | Re-execution after a full set of fresh deliveries is the intended counting model, not replay. Replay of spoke state updates is separately blocked by hub-side snapshot nonces (see HubHandler) |
| Cross-pool isolation: no operation on pool A can change pool B's escrow funds, accounts, holdings, queues, or vault links | y | - | - | Composition of typed ids (`PoolId`/`ShareClassId`/`AssetId`), per-pool CREATE2 escrows, per-pool accounting sessions, and the per-key FV isolation rows below |
| Bystander isolation: an investor-initiated vault operation moves tokens only between the controller, owner and receiver, the escrows, the vault, the fee source and recipient, and the configured liquidity route; no third party's balance changes | y | - | - | |
| Price authority: prices used in investor flows are set only by hub-authorized messages; no investor operation changes price per share (reported or implied) | y | - | e2e `doomsday_pricePerShare_never_changes_after_user_operation` | No investor or manager operation moves a vault's price per share, the spoke's notified price or the hub's; only repricing handlers may |
| Share issuance is bounded on-chain by the assets actually received | n | - | - | Issuance amounts and NAV per share are manager-supplied inputs: the protocol verifies the ledger arithmetic, not its correspondence to deposits, and `ShareToken` carries no supply cap. Pool backing is off-chain by construction, so no on-chain bound is available. Accepted risk: a compromised or faulty pool manager can issue unbacked shares, constrained only by the pool's manifest policy (the guardian timelock gates ward grants, not manager calls). `Spoke.issue` mints an arbitrary amount to an arbitrary recipient, so neither the quantity nor the destination is bound to a deposit |
| Prices are bounded by a rate-of-change limit | n | - | - | Hub-side, only authorization and a no-future-timestamp check are enforced; magnitude is unconstrained, so one authorized message can move price per share by any factor (`computedAt` is not monotone hub-side either, see the ShareClassManager section; the spoke applies prices non-decreasingly in `computedAt`). A protocol-level drift bound is not workable for RWA share classes whose NAV legitimately gaps (revaluations, defaults, illiquid marks); bounding belongs to pool-level policy in the manifest and valuation contracts |
| Full-exit liveness: an investor with a fulfilled redemption can always claim the full max amount | y | - | e2e `vault_claimMax`, `VaultInvariants` | How the vault rounds partial claims is specified in `src/vaults/SPECIFICATION.md` (ERC-7540 / ERC-4626 conformance). The claim pays exactly the max, and the max is the whole ledger, unfolded slices included. Except while the escrow is over-reserved: `withdrawReserved` pays only out of the unreserved balance, so a claim then fails on the escrow's `InsufficientBalance` until the escrow is funded or unreserved. Three documented ways in: a manager reserving ahead of arrival (`testOverReservationHoldsBackRedeemClaims`), sibling vaults on one position reserving between them, and a redemption settled against cash reserved for a pending deposit (`src/vaults/SPECIFICATION.md`, claimable backing). The suite asserts that exact failure in that state and success outside it, over a six- and an eighteen-decimal asset |
| Root recovery: Root is a ward on every core contract, so any misconfiguration short of a Root compromise is recoverable by spell; all rely paths flow through the guardian timelock | y | - | - | |

## Core specification

Per-contract properties for the hub, spoke, and messaging layers.

### Hub (`src/core/hub/Hub.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Every manager-facing pool entrypoint requires a registered manager of the pool and passes the installed manifest's enforcement when one is set | y | - | - | `initiateAuthorization`/`unauthorizeSpokeCall` are deliberately manager-gated with no manifest check: initiation is pre-staging, revocation only reduces capability |
| `file`, `createPool`, and the journal primitives `updateAccountingAmount`/`updateAccountingValue` are ward-gated | y | - | - | |
| `createPool` mints only local pool ids (`poolId.centrifugeId()` equals the local network) | y | - | - | |
| Accounting is locked after every Hub external call: each `unlock(poolId)` pairs with a `lock()` in the same call, so the transient session never leaks across calls | y | - | - | |
| `updateAccountingAmount`/`updateAccountingValue` post one balanced debit/credit pair (zero diffs are skipped) and can never revert `Unbalanced` at `lock()` | y | - | - | Liveness of the message-driven accounting path |
| A manager of pool A can never mutate pool B's accounts via `updateJournal`: the accounting session scopes all entries to the unlocked pool | y | - | - | |
| `initializeHolding` requires an existing share class, a registered asset, and four existing accounts; any amount tracked before initialization is valued and journaled as principal at initialization | y | - | - | No untracked-value gap between early `updateAssets` and initialization |
| `setAdapters` is rejected while batching | y | - | - | |
| A remote `SetPoolAdapters` is dispatched over the current outgoing adapter set and targets the same session id as the local install | y | - | - | The reconfig message always travels a set the destination still shares; local and remote converge on `targetSessionId` |
| `managerCall` ETH attribution is explicit: a local call carries exactly `msgValue()`, a remote call carries zero | y | - | - | |
| `requestCallback` is accepted only from the pool's registered hub request manager for the asset's origin network | y | - | - | |
| Every share-price update and asset-price notification accrues fees when a `feeAccrual` hook is installed | y | - | - | |
| A pool's manifest can only change with the current manifest's consent | n | - | - | A ward can swap it directly via `setManifest` as break-glass, mirroring the HubRegistry ward-bypass exception |
| `pricePoolPerAsset` reverts for a holding that was never initialized | n | - | - | Returns the 1.0 bootstrap default instead; `notifyAssetPrice` can broadcast 1.0 until the holding is initialized |

### HubHandler (`src/core/hub/HubHandler.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| All message handlers are ward-gated (Gateway/MessageProcessor only) | y | - | - | |
| `updateAssets` journals exactly the value realized by the holding mutation, and only when the holding is initialized; uninitialized holdings track amount with no account movement | y | - | - | Keeps `accountValue(Asset) == holdings.value` inductively |
| Every accepted `updateAssets`/`updateShares` consumes the per-`(pool, scId, network)` snapshot nonce exactly once, so replayed or reordered spoke updates revert | y | - | - | |
| `request` routes only to the pool's registered request manager for the asset's origin network; with none registered it fails closed and the message stays retryable | y | - | - | |
| The bridging hook (a pool-chosen contract invoked on cross-chain share transfers, set via `HubRegistry.setBridgingHook`) cannot alter a transfer before it is applied | n | - | - | Trusted pool-chosen code may rewrite receiver, amount, gas, and refund; a hook that rewrites `amount` desyncs hub-side origin issuance from the spoke's actually-burned supply |

### Accounting (`src/core/hub/Accounting.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Account registration is permanent and write-once; `isDebitNormal` never changes after creation | y | #278 | - | |
| Only wards can create accounts or post journal entries | y | #278 | - | |
| A journal always balances: per pool, the sum of debits equals the sum of credits, enforced by the transient lock before `lock()` completes | y | #278 | e2e `property_accounting_books_balance`, `hub_updateJournal` | |
| `addDebit`/`addCredit` change exactly the target account's total by exactly the posted amount; all other accounts are untouched | y | #278 | - | |
| `totalDebit` and `totalCredit` are monotonically non-decreasing and isolated per pool | y | #278 | - | |
| `totalDebit` and `totalCredit` stay below `int128.max` in practice, protecting downstream int128 casts in consumers | y | - | e2e `property_accountTotalsFitInt128` | Observed under fuzzing; not enforced in code |
| `accountValue()` nets debit/credit consistently with the account's normal side and never reverts for an existing account | y | #278 | e2e `doomsday_accountValue`, `property_viewsNeverRevert` | Nonexistent accounts revert `AccountDoesNotExist` |
| A decrease in valuation never increases `accountValue` | y | - | e2e `property_decrease_valuation_no_increase_in_accountValue` | |
| Journal ids are unique per pool; all entries for one pool within a transaction share a single journal id, and ids embed the pool id so they can never collide across pools | y | #278 | - | |
| A session must be open to close it: `lock()` reverts when no pool is unlocked; `unlock(PoolId(0))` is rejected | y | #278 | - | `PoolId(0)` is the locked-state sentinel, so it can never open a session or brick accounting |
| Zero-value and self-offsetting journal entries are rejected | n | #278 | - | Normal double-entry bookkeeping accepts them; `accountValue()` nets to zero either way and nothing reads `lastUpdated` for a security decision |

### Holdings (`src/core/hub/Holdings.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| All mutations are ward-gated; a holding is initialized iff it has a non-zero valuation (write-once) | y | #278 | - | |
| `increase` values only the realized (post-netting) amount; value is additive and conserved | y | #278 | - | |
| `decrease` removes carrying value pro-rata to the realized amount, capped at stored value, so it never over-journals | y | #278 | - | |
| A holding with zero derived amount carries zero value (no phantom NAV stranded on an emptied holding) | y | #278 | e2e `property_holdingZeroAmountHasZeroValue` | |
| Holdings value equals `accountValue` of the corresponding asset account | y | - | e2e `property_accounting_and_holdings_soundness` | Cross-contract Holdings/Accounting consistency, asserted as equality: the asset account is shared by every holding booked on it, so it is compared with their summed value. The journal handler stays off the asset account, which a manual entry moves by design |
| Immediately after `update()`, `holdings.value` equals `getQuote(holdings.amount)` (mark-to-market coherence) | y | - | e2e `hub_updateHoldingValue` | |
| `deficitCount(pool, network)` equals the number of holdings whose decreases exceed increases | y | #278 | e2e `property_deficitCountMatchesHoldings` | FV additionally proves the counter is bucketed by the reporting `centrifugeId`, so NAV automation's deficit gating and the counters agree; keying assumes the reporting network and `assetId.centrifugeId()` name the same network (holds today, noted for auditors) |
| The snapshot nonce increments by exactly one per update and is monotonic; `onSync` fires only when the snapshot flag is set | y | #278 | - | |
| Holdings are isolated per `(pool, scId, asset)` | y | #278 | - | |
| Cumulative `increasedAmount`/`decreasedAmount` counters survive holding initialization; nothing ever resets them | y | #278 | - | Initialization only sets valuation/accounts; tracked amounts are never lost |
| `decrease` reprices symmetrically with `increase` | n | #278 | - | Intended: a live oracle quote on decrease would break `amount == 0 => value == 0`; the reverting-oracle asymmetry is a liveness quirk only |
| Over-decrease netting reprices at netting time | n | #278 | - | The cumulative counters net amounts, not values, so the netted portion is not revalued at the current quote |
| `updateValuation` forces a revaluation | n | #278 | - | `IValuation` is a pool-chosen trusted dependency; a stale value persists until the next `update()` |
| A dropped snapshot message cannot stall the pipeline | n | #278 | - | Strict nonce ordering means a gap stalls `submitQueued*` until the messaging layer recovers the message; `callOnSyncSnapshot` spam is ward-gated |

### ShareClassManager (`src/core/hub/ShareClassManager.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Share-class existence is monotonic and irrevocable; the id is deterministic from `(pool, index)` and globally unique | y | #278 | - | |
| Salt is write-once, pool-prefixed, and reuse is rejected | y | #278 | - | |
| Metadata name/symbol length bounds are enforced; add/update are ward-gated and require existence | y | #278 | - | |
| Issuance and revocation change totals by exactly the requested amount; total issuance equals the sum of per-network nets | y | #278 | e2e `balanceSheet_submitQueuedShares` | Asserted on submission: hub issuance moves by exactly the queued net, then equals the share supply, and total issuance equals the per-network sum |
| Issuing with non-zero NAV per share increases total issuance; revoking decreases it | y | - | e2e `balanceSheet_submitQueuedShares`, `property_shareQueueCommutativity` | |
| Prices and `computedAt` are stored exactly; the initial price is zero; price updates are isolated per share class | y | #278 | - | |
| A share price's `computedAt` can never be in the future | y | #278 | - | `CannotSetFuturePrice`; complements the accepted "can be in the past" exception below |
| `addShareClass` requires the pool to exist | y | #278 | - | |
| A stored share price is always non-zero | n | #278 | - | Zero is a valid price (e.g. a zero-NAV pool) |
| `computedAt` is monotonically increasing | n | #278 | - | It is an off-chain "as-of" date, not a sequence number |
| Per-network revocations never exceed issuances | n | #278 | - | A cross-chain revoke can precede the Hub-side issuance sync; only transiently |
| The per-network `issuance()` view never reverts | n | #278 | - | Fails closed (`NegativeIssuance`) while revocations transiently exceed issuances during cross-chain sync lag; consumers must tolerate the revert window |

### HubRegistry (`src/core/hub/HubRegistry.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Pool and asset registration is permanent and write-once; decimals are immutable and existence is monotonic | y | #278 | - | |
| Registration is ward-gated, rejects duplicates, and records the correct initial manager, currency, and decimals | y | #278 | - | |
| `registerPool` requires a registered currency; `registerAsset` rejects the null `AssetId` and decimals > 18 | y | #278 | - | |
| Currency updates require an existing pool, a registered currency, and matching decimals | y | #278 | - | |
| Metadata is stored verbatim and isolated from currency and other pools | y | #278 | - | |
| Manager assignment is ward-gated, pool-scoped, and independent across pools and addresses; the zero address can never be a manager | y | #278 | - | |
| Dependency setters (incl. `setBridgingHook`) are ward-gated and existence-gated | y | #278 | - | |
| Authorization pre-staging enforces manifest classification, a non-zero delay, and non-replay; ids are namespaced by manifest + per-pool `manifestNonce`, so a manifest swap (even swap-back) invalidates them | y | #278 | - | |
| Authorization consumption is single-use, timing-enforced, and only by the pool's current manifest | y | #278 | - | |
| The three `decimals()` overloads return registered values and revert for unregistered assets/pools | y | #278 | - | |
| A pool always retains at least one manager | n | #278 | - | Removing the last manager is self-inflicted; ward-level spell recovery exists |
| The manifest timelock cannot be bypassed | n | #278 | - | Wards bypass it as documented break-glass; wards are already behind the guardian timelock |
| The manifest expiry window and delay have a protocol-enforced floor | n | #278 | - | That is the pool policy contract's job |
| The authorization id binds the executing caller | n | #278 | - | Deliberate initiator/executor separation; the manifest enforces the caller at consumption |
| `setHubRequestManager` always keeps hub and spoke in sync | n | #278 | - | Ward-direct calls skip the spoke sync as break-glass and can orphan in-flight state; the normal Hub path syncs |
| The bridging hook can never be disabled | n | #278 | - | `address(0)` is the documented clear op, manager-gated |

### Spoke (`src/core/spoke/Spoke.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `file` is ward-gated and updates exactly one recognized dependency; unknown params revert | y | #278 | - | |
| Ward and manager mappings are binary; every balance-sheet asset/share method reverts for a non-manager | y | #278 | - | A reverting manifest blocks even managers (fail closed) |
| `deposit`/`noteDeposit`/`withdraw`/`withdrawReserved` change escrow accounting by exactly the amount and are isolated to the target `(scId, asset, tokenId)` | y | #278 | e2e `balanceSheet_deposit`, `balanceSheet_noteDeposit`, `balanceSheet_withdraw`, `balanceSheet_withdrawReserved` | Exact deltas and isolation from the share class's other asset are asserted inline after each call; ERC-20 assets only, so the ERC-6909 paths are not fuzzed |
| `reserve`/`unreserve` change the bucket and aggregate by exactly the amount without touching `total` | y | #278 | e2e `balanceSheet_reserve`, `balanceSheet_unreserve` | |
| Queue deltas are correct and directional per operation; zero-amount operations skip the queue; a flush resets the delta and increments the nonce | y | #278 | e2e `balanceSheet_deposit`, `balanceSheet_withdraw`, `balanceSheet_reserve`, `balanceSheet_unreserve`, `property_shareQueueFlipBoundaries`, `balanceSheet_submitQueuedAssets` | |
| Cross-chain share bridging requires owner-or-ward, the bridger role, a non-local destination, and `canBridge`; it rejects zero amounts, burns before messaging, and leaves the Spoke net-zero in shares | y | #278 | - | |
| Spoke share custody is net-zero: `revoke` and `crosschainTransferShares` pull, approve, and burn exactly the operated amount within one call, leaving no residue | y | - | - | Extends the FV bridging net-zero row to `revoke`; shares donated directly to the Spoke address are out of scope |
| Balance-sheet operations resolve the escrow deterministically from `poolId`, so operations on pool A can never move pool B's escrow funds | y | - | - | |
| Asset operations that touch the queue require a registered asset id, so unregistered assets can be neither queued nor accounted | y | - | - | Enforced in `_queueAssets` via `assetToId(..., revertOnNull)`. `withdrawReserved` has no registration check of its own; it is unreachable for an unregistered asset because a reserve must exist first |
| Shares are minted and burned only through the share class's registrar; the Spoke has no direct mint/burn access on the token | y | - | - | |
| `registerAsset` is deliberately permissionless: registration grants no privileges, metadata/decimals are read from the asset itself, and re-registration cannot change an existing id | y | - | - | |
| `request` accepts only the pool's request manager (raw `msg.sender`); `managerCall` uses the resolved `msgSender`/`msgValue` | y | #278 | - | |
| Batched multicall isolates the initiator (`msgSender`) and zeroes `msgValue` inside a batch; the gateway can never be treated as an authorized caller; reentrancy into protected functions is blocked | y | #278 | - | |
| The escrow always holds sufficient balance to cover queued asset increases | n | - | - | Known, acknowledged break: out-of-band accounting (`noteDeposit`) can queue increases not backed by held tokens. The former e2e property (`property_availableGtQueued`) failed as expected and is not carried into the current suite |
| A bridged transfer can never be stranded by its receiver | n | #278 | - | Receivers are opaque bytes32; a destination mint failure stays retryable until an explicit `clearFailedMessage` |
| `sender_` in `crosschainTransferShares` is authenticated | n | #278 | - | Attribution cannot be bound to the caller without breaking forwarding patterns (a router bridging on an investor's behalf); the bridger role is trusted |
| Escrow credits always correspond to a token pull | n | #278 | - | `noteDeposit` credits without a pull (out-of-band funding); reservations can exceed total (reserve ahead of arrival). Documented design |
| An empty queue submit is rejected | n | #278 | - | A zero-delta update is a legitimate manager-gated snapshot heartbeat |
| `managerCall` restricts its targets | n | #278 | - | Permissionless by design; the `fromSpoke` target self-validates |
| No escalation via config surfaces (Gateway-as-ward, zero-address `file`, mutable-decimals re-registration, ERC-777 reentrancy on deposit) | n | #278 | - | Trusted-config / pool-chosen-asset / CEI-covered respectively, all documented |

### SpokeHandler (`src/core/spoke/SpokeHandler.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| All message handlers are ward-gated (MessageProcessor/MessageDispatcher only, plus Root) | y | - | - | The MessageDispatcher rely covers the same-chain short-circuit path |
| `addPool` deploys the escrow before registering the pool, so an active spoke pool always has its escrow at the deterministic address | y | - | - | |
| `addShareClass` requires a non-zero registrar and deploys the share token through it before registry linkage: no registered share class without a live token contract | y | - | - | |
| `executeTransferShares` mints and forwards in the same call: the handler holds the shares only transiently within the call (net-zero), and a hook-rejected receiver reverts the whole (retryable) message | y | - | - | No stranded mint; matches the Spoke dead-receiver exception |
| `updateVault(DeployAndLink)` registers and links atomically: the vault the factory returns is never observable registered-but-unlinked | y | - | - | Whether the vault exists before the message is the factory's choice. The VDK's `VaultFactory` deploys nothing inside it: its vaults are deployed ahead by a spoke transaction and sit unregistered until the message lands (src/vaults/SPECIFICATION.md) |
| `requestCallback` routes only to the pool's currently installed request manager and reverts when none is set | y | - | - | |

### SpokeRegistry (`src/core/spoke/SpokeRegistry.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Each pool gets a permanent non-zero activation timestamp; the null `PoolId` is rejected | y | #278 | - | |
| Each share token maps to at most one `(pool, scId)`; a token swap retires the outgoing token's reverse mapping | y | #278 | - | |
| A share token can be linked only if its code is already deployed, so a pool cannot reserve another pool's yet-undeployed deterministic token address | y | - | - | The `NotAContract` guard in `_linkToken` |
| Manager/bridger roles are ward-gated, pool-scoped, independent, and require an active pool | y | #278 | - | |
| Manifest install and the consume-only authorization counter are integrity-preserving (the counter never underflows) | y | #278 | - | |
| Authorization ids are namespaced by a per-pool `manifestNonce`, so a manifest swap cannot resurrect matured authorizations | y | #278 | - | |
| Vault register/link/unlink enforce identity checks: existing share class, matching `(asset, tokenId)`, no re-registering a linked vault, no linking with a mismatched assetId | y | #278 | - | Needs a Certora re-run: `autospec_Vault_Management.spec` asserts a stronger revert set than the current code (it summarizes `vault.poolId()`/`scId()`/`vaultKind()` calls and a `requestManager != 0` precondition that `registerVault` no longer performs) |
| For ERC-20 assets the share token's ERC-7575 vault pointer is set and cleared only by an explicit registrar `SetVault` managerCall; linking and unlinking a vault leave it alone | y | - | - | Multiple vaults per tuple never clobber each other, since no link or unlink touches the pointer |
| `createAssetId` allocates a fresh non-zero id with a consistent bidirectional mapping; rejects a zero asset, zero `centrifugeId`, and duplicate registration | y | #278 | - | |
| Share/asset price updates are ward-gated, require registration, and are non-decreasing in `computedAt` (same-timestamp overwrite permitted for same-second corrections) | y | #278 | - | |
| Price validity (`computedAt != 0`) is permanent: a price never transitions valid to invalid | y | - | - | |
| Core enforces price freshness | n | - | - | Intended: arbitrarily stale prices are accepted at face value; staleness policy is delegated to managers/valuations. `computedAt` monotonicity is the only core guarantee |
| Vault registration is write-once | n | - | - | Intended: registration is provisional until link; an unlinked vault can be re-registered under a different tuple. Worth flagging for auditors since stale registrations are overwritable |
| `setRequestManager` rejects the zero address | n | - | - | Intended clear-op to disable the route; requests then revert `InvalidRequestManager` |
| Changing a pool's request manager preserves vault links | y | - | - | Vault records are keyed by vault address and carry no manager component, so `setRequestManager` cannot orphan them |
| Every linked vault has a non-zero request manager | n | #278 | - | `linkVault` performs no request-manager check, and `requestManager` is a single per-pool slot that may be unset; an instant-only vault (no request policy) has none |
| A token swap resets the share price | n | #278 | - | Price is share-class-scoped, not token-scoped |
| A stored price is always non-zero | n | #278 | - | Zero is valid (zero-NAV) |
| Share and asset prices arrive atomically and in order | n | #278 | - | They are separate hub messages and tolerate out-of-order delivery; asset prices can exist for `(scId, asset)` pairs that have no linked vault or holding |
| Spoke authorizations are caller-scoped | n | #278 | - | Same initiator/executor separation as the hub ledger |

### SnapshotQueue (`src/core/spoke/SnapshotQueue.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| All queue and flush mutations are ward-gated; only the Spoke (and Root as break-glass) can enqueue or flush | y | - | - | |
| The share queue nets issues against revokes; flips between positive and negative net positions are detected exactly | y | - | e2e `property_shareQueueFlipBoundaries`, `property_deltaCheck` | |
| The net queued share position equals total issued minus total revoked | y | - | e2e `property_shareQueueCommutativity` | Stated as: the signed queued delta equals the share supply minus the hub's issuance for the network |
| A zero share delta is canonicalized to non-positive (`delta == 0 => isPositive == false`) | y | - | - | Prevents sign ambiguity in the flushed payload |
| Asset flows accumulate gross: queued deposits and withdrawals never net against each other before flush; netting happens exactly once, at flush time (`netAmount = abs(deposits - withdrawals)`) | y | - | - | |
| `queuedAssetCounter` equals the number of non-empty asset queues and never exceeds the number of tracked assets | y | - | e2e `property_assetQueueCounterConsistency`, `property_assetCounterBounds` | |
| A flush clears exactly its target: `flushAssets` clears one asset queue, leaving other asset queues and the share delta untouched; `flushShares` clears the share delta, leaving asset queues untouched | y | - | e2e `balanceSheet_submitQueuedAssets`, `balanceSheet_submitQueuedShares` | |
| Every flush (asset or share) consumes exactly one nonce from the shared per-`(pool, scId)` sequence, and nonces strictly increase | y | - | e2e `property_nonceMonotonicity`, `balanceSheet_submitQueuedAssets`, `balanceSheet_submitQueuedShares` | The nonce sequence is shared across asset and share flushes: the hub applies updates strictly in flush order across both message types |
| A flush reports `isSnapshot = true` iff it leaves the share class fully drained (zero share delta and no other non-empty asset queue) | y | - | - | The hub-side snapshot coherence signal everything hinges on; only partially implied by the queue-submission fuzz property |
| An equal-in/out asset queue (deposits == withdrawals != 0) still flushes a zero-net update, decrements the counter, and consumes a nonce | y | - | - | Intended: keeps counter/nonce bookkeeping consistent |

### Escrow (`src/core/spoke/Escrow.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `poolId` is immutable; there is no delegatecall or selfdestruct surface | y | #278 | - | |
| Every state-changing function is ward-gated; wards are binary and only rely/deny change them | y | #278 | - | |
| `deposit`/`withdraw` change `total` by exactly the amount, preserve `reserved`, and are isolated per `(scId, asset, tokenId)` | y | #278 | e2e `balanceSheet_deposit`, `balanceSheet_withdraw` | |
| `reserve`/`unreserve` mirror the bucket and aggregate exactly and never touch `total` | y | #278 | - | |
| `holding.reserved` always equals the sum of its per-`(reserver, reason)` buckets | y | #278 | e2e `property_escrowReservedSumConsistency` | |
| `withdraw` succeeds only when `total - reserved >= value`: reserved funds are never withdrawable | y | #278 | e2e `balanceSheet_withdraw` | The handler also tries amounts past the available balance |
| `availableBalanceOf` returns `total - reserved`, saturating at 0; `authTransferTo` reverts on insufficient physical balance and moves exactly the amount | y | #278 | - | |
| The escrow's raw token balance for an asset equals the sum of `holding.total` across share classes | y | - | e2e `property_escrowBalanceMatchesHoldingTotal` | |
| `reserved` never exceeds `total` | n | #278 | e2e (driven, not asserted) | Over-reservation (reserve ahead of arrival) is legal by design; `withdraw` then fails closed. The suite drives it (`balanceSheet_reserve`) and checks that holdings conservation and reservation consistency survive it |
| A ward set cannot become empty | n | #278 | - | Standard `Auth` self-deny; recovery is a ward-level spell |
| `(reserver, reason)` buckets are tamper-proof per identity | n | #278 | - | They are trusted-caller data, not authenticated identities; per-key isolation still holds |
| `authTransferTo`/`recoverTokens` keep the ledger in sync with custody | n | #278 | - | Accounting and custody are decoupled by design; the composition invariant is verified in the Spoke run |

### EscrowFactory (`src/core/spoke/factories/EscrowFactory.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Escrow addresses are deterministic: the `escrow()` view and `newEscrow` deployment always agree | y | - | - | CREATE2 with salt = `poolId`; the address is fixed by (factory address, Escrow creation code, `poolId`), so it is stable across networks only while the factory address and escrow bytecode are |
| `newEscrow` succeeds at most once per pool: an escrow can never be redeployed or swapped | y | - | - | |
| A fresh escrow's ward set is exactly {root, spoke}, and the factory denies itself before returning | y | - | - | If `spoke` is unfiled the effective set degrades to {root} (plus an inert `address(0)` ward entry); recoverable via Root |
| The deployed escrow's immutable `poolId` equals the requested pool | y | - | - | |

### Gateway (`src/core/messaging/Gateway.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `send`/`file`/`updateManager` are ward-gated; `file` updates exactly one recognized dependency | y | #278 | - | |
| `handle`/`clearFailedMessage` require a ward or the message pool's manager | y | #278 | #266 | |
| Pause halts `handle`/`retry`/`send`/`repay` while admin functions stay callable | y | #278 | #266 | |
| `handle` rejects a local-network source and enforces the expected source network | y | #278 | #266 | FV covers the local-source half (`handle_rejects_local_centrifuge_id`); the expected-source mismatch revert is not asserted by a rule because `messageSourceCentrifugeId` is summarized |
| The failed-message counter is raised only by `handle` failures and lowered only by `clear`/`retry`, per `(network, messageHash)`; `clear` never executes; `retry` forwards and propagates reverts | y | #278 | #266 | Fuzz bounds (ghost counters in the `recon-messaging` suite): `failedMessages <= deliveries` and `(callCount + failedMessages) * threshold <= deliveries` |
| A message that has not failed can be neither retried nor cleared | y | #278 | #266 | |
| `send` rejects empty/oversized messages and over-budget gas; without unpaid mode it reverts on insufficient ETH | y | #278 | - | |
| The underpaid-batch counter/gasLimit lifecycle holds (zero counter implies zero gasLimit; full refund on shortfall) | y | #278 | - | |
| ETH is conserved: exactly the adapter cost is forwarded and the remainder refunded, on every `send`/`repay`/`withBatch` path | y | #278 | - | |
| While batching, `send` defers adapter calls and rejects ETH; the reentrancy flag blocks injection mid-flush; all transient batching state (incl. `isBatching`) is cleared after the outermost `withBatch` | y | #278 | #266 | |
| Inbound batch framing is exact: the walk consumes `messageLength`-sized slices with no gaps or overlap; a truncated or overrunning tail or an unknown type byte reverts the whole batch atomically | y | - | - | Framing failures revert the entire `handle`; only processing failures are isolated per sub-message |
| Batch pool homogeneity: every sub-message in an inbound batch carries the batch's own `poolId` | y | - | - | Manager auth is checked once against the batch pool; a heterogeneous batch would bypass per-pool authorization |
| Source enforcement applies to each sub-message inside a batch, not just the batch head | y | - | - | |
| Gas starvation cannot forge failures: an under-gassed `handle` reverts `NotEnoughGas` instead of recording a failure, and failure bookkeeping runs on a reserved gas budget | y | - | - | Anti-griefing: a malicious relayer cannot poison `failedMessages` |
| Outbound batches are partitioned per `(destination, pool)`; each accumulated batch dispatches exactly once at flush | y | - | - | |
| Flushed batch content equals the concatenation of messages in send order; the batch gas limit equals the sum of per-message limits, capped incrementally by `maxBatchGasLimit` | y | - | - | |
| A batched flush is always fully paid: `send` inside batching rejects ETH and ignores its `unpaidMode` flag, and the flush dispatch runs with unpaid mode off, so a shortfall reverts the whole transaction | y | - | - | Unpaid registration can only arise from unbatched sends |
| `retry` cannot front-run `clearFailedMessage` | n | #278 | - | `clear` is for un-retryable messages; `retry` is permissionless by design |
| `clearFailedMessage` access control is robust to a malicious `messageProperties` | n | #278 | - | It is a ward-set trusted dependency, same class as `processor`/`adapter` |
| A gateway manager cannot inject hub-originated messages | n | #278 | - | Intentional and pool-scoped; grant only to constraining contracts |
| The underpaid `gasLimit` is never overwritten | n | #278 | - | Keyed by batch hash, deterministic; keeping the latest is more correct |
| `repay` cannot run while a batch is being dispatched | n | #278 | - | Unguarded on purpose: it touches only persistent state, and the `_isSendingBatch` guard protects transient batch structures |
| A batched flush re-checks pause before dispatching | n | #278 | - | Every accumulated `send` already passed the pause check in the same tx |

### MultiAdapter (`src/core/messaging/MultiAdapter.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| A session id never collides with earlier never-cleared state: each `setAdapters` bumps the active id, ids strictly increase, and they revert at the 65535 ceiling rather than recycle | y | #278 | #266 | The ceiling clause is not FV'd: the specs assume `activeSessionId < 65535` and treat wraparound as unreachable. In code the checked `uint16 + 1` panics rather than wrapping |
| `setAdapters` applies only if the resulting session id equals the caller-supplied `targetSessionId` | y | - | - | Race-free remote reconfiguration: a delayed or replayed `SetPoolAdapters` cannot land on a later session than intended. No rule asserts `UnexpectedSessionId`, though the parameter is threaded through the #278 specs; candidate for the next spec update |
| The active adapter set is non-empty when configured, pairwise distinct, with `1 <= threshold <= quorum`; a zero threshold is rejected unless the list is empty (the route-disable operation: clearing all adapters intentionally severs the route) | y | #278 | #266 | |
| Config ops (`setAdapters`, `blockSession`, `unblockSession`) require a ward or pool manager; `updateManager` and `send` are ward-gated | y | #278 | #266 | |
| Blocking the active session clears the outbound set and stashes config; unblock restores it unless superseded; double-block is rejected; blocked sessions reject inbound | y | #278 | #266 | |
| Only adapters registered in the payload's session (or a manager on their behalf) may vote/execute; votes are session/pool/message isolated; one adapter moves only its own slot | y | #278 | #266 | |
| Pool-scoped inbound payloads verify against the pool's own adapter set once configured | y | - | - | |
| Pool-independent messages (`ScheduleUpgrade`/`CancelUpgrade`/`RegisterAsset`) always verify over the global adapter set; a `SetPoolAdapters` for a not-yet-configured pool falls back to it | y | - | - | The fallback is limited to the one real-pool-id message type that establishes the pool set |
| `execute` forwards only once votes meet the threshold; votes are consumed before the Gateway call (CEI); the session prefix is stripped before delivery | y | #278 | #266 | Fuzz bounds (ghost counters in the `recon-messaging` suite): `callCount * threshold <= deliveries`, positive vote sum `<= deliveries` |
| Across all sessions, weighted executions never exceed cumulative deliveries: no message executes without quorum, even across reconfigurations | y | - | #266 | Includes a regression guard for the "Alex-1" finding (message replay across adapter-set reconfigurations) |
| `send` prepends the active session id and dispatches the identical payload to every active adapter exactly once; an empty adapter set reverts | y | #278 | #266 | |
| `send` pays each adapter its own estimate, refunds the surplus, and retains no ETH | y | #278 | #266 | |
| A pool manager cannot forge quorum beyond the documented capability (voting on behalf of a registered adapter of its own pool): a manager can never conjure votes for adapter slots it does not control | y | #278 | - | |
| The same payload can never execute twice | n | #278 | - | Deliberate at-least-quorum counting, not a replay bug: votes are per-adapter tallies that execution decrements, so if every active adapter re-delivers the same payload, the tallies replenish and it executes again |
| Votes are wiped on session changes | n | #278 | - | Vote keys are session-prefixed; superseded sessions stay open, and an adapter that missed an execution round has its tally decremented below zero. The intended counting model |
| Dispatch is resilient to a reverting adapter or refund address | n | #278 | - | All-or-nothing quorum dispatch over trusted adapters, by design. The same acceptance applies to the race where an adapter's `estimate` changes between quoting and `send` |

### MessageDispatcher (`src/core/messaging/MessageDispatcher.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Every `send*` either short-circuits to the local handler (destination equals the local network) or serializes to the Gateway: exactly one of the two, never both (sole exception: `sendSetPoolAdapters`, see its row below) | y | - | - | |
| Local/remote path equivalence: for every message type, the local short-circuit invokes the same handler method with the same arguments as `MessageProcessor.handle` would after a serialize/deserialize round-trip | y | - | - | The property that makes same-chain pools behave identically to cross-chain ones; currently untested anywhere |
| Routing key correctness: pool-homed sends go to `poolId.centrifugeId()`, asset-homed sends to `assetId.centrifugeId()`, transfer execution to `targetCentrifugeId` | y | - | - | The mirror of receive-side source classification; the two sides must agree or messages are undeliverable |
| The dispatcher retains no ETH: `msg.value` is fully forwarded or refunded on every path | y | - | - | |
| All `send*` are ward-gated, including the `sendUpdateHoldingAmount` ABI shim | y | - | - | Subtle: the shim has no `auth` modifier itself; it inherits auth through its internal call to the public `sendUpdateAssets`, since internal calls preserve `msg.sender`. Easy to break in a refactor |
| `sendUpdateHoldingAmount` ignores its price argument and is behavior-identical to `sendUpdateAssets` | y | - | - | v3.1.0 BalanceSheet ABI compat; the hub re-values at its own valuation |
| `sendSetPoolAdapters` rejects the local network | y | - | - | Local adapter config goes through direct ward/manager calls, not the MessageDispatcher |
| Unpaid mode is used only for `sendRequest`/`sendRequestCallback` (caller-chosen) and hub-forwarded transfer legs that were prepaid on the origin chain | y | - | - | |

### MessageProcessor (`src/core/messaging/MessageProcessor.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `handle` is ward-gated (only the Gateway is relied): no direct message injection | y | - | - | |
| Dispatch is total and unambiguous: every `MessageType` except `_Invalid` routes to exactly one handler call; unrecognized kinds revert | y | - | - | |
| The processor is stateless between messages: a failed message leaves no partial state, so retry is idempotent-safe | y | - | - | All state lives in the target handlers |
| Source attribution integrity: the Gateway-verified `centrifugeId` is forwarded unmodified to every handler that keys state by source network | y | - | - | Deficit, snapshot, and sender data are keyed by source; the processor must not launder it |
| Enum bounds are enforced: out-of-range manager/vault-update kind bytes revert, and `UpdateManager` fan-out targets exactly the one contract selected by the kind | y | - | - | Malformed wire values cannot select an unintended contract |
| Inbound `InitiateTransferShares` uses unpaid mode with no refund address: a remote-initiated transfer never expects ETH on the hub chain | y | - | - | |

### MessageLib (`src/core/messaging/libraries/MessageLib.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `deserialize(serialize(x)) == x` field-exact for every message struct | y | - | unit | Fuzzed per type in `TestMessageLibIdentities` (all 24 types) |
| `messageLength(serialize(x))` equals the actual serialized length for every type, including dynamic payloads and `SetPoolAdapters`' 32-byte-per-adapter tail | y | - | unit | Asserted alongside each round-trip case. The length table is hand-maintained, so a one-byte mismatch would silently corrupt Gateway batch walking |
| Message type codes are append-only ABI: the enum never reorders across releases | y | - | - | Wire-format compatibility across mixed-version networks; enforceable as a snapshot test |
| `messageLength` reverts for `_Invalid` (0) and any code above the max enum value | y | - | unit | Prevents zero-length slices causing infinite batch-walk loops. The `_Invalid` case is exercised directly; the above-max branch shares the same require |
| Every pool-dependent message carries its `PoolId` big-endian at offset 1 | y | - | unit | `messagePoolId`/`messageSourceCentrifugeId` blind-read offset 1, so a serializer reordering fields would break routing and manager auth; asserted per type alongside each round-trip case |
| Source classification is exhaustive: every message type maps to exactly one class (pool-homed, asset-homed, mainnet-pinned, or unrestricted), and zero-home ids revert instead of falling through to "any source" | y | - | unit | A new type defaulting into the wrong class either bricks (rejected from its true source) or opens cross-chain spoofing. `testMessageSourceCentrifugeIdForEveryMessageType` loops every type code, so a new type fails the test until classified |
| `ScheduleUpgrade`/`CancelUpgrade` are accepted only from the mainnet `centrifugeId` | y | - | - | Root-upgrade authority is pinned to Ethereum |
| `routePoolId` returns the message's own pool, except `SetPoolAdapters` for a not-yet-configured pool, which falls back to the global adapter set | y | - | - | Bootstrap path |
| `messageExtraGasLimit` offsets read the actual `extraGasLimit` field, not adjacent bytes | y | - | unit | Asserted per type alongside each round-trip case. Shares the hand-maintained-constant risk class of the length table |

### PricingLib (`src/core/libraries/PricingLib.sol`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Conversions honor the requested rounding direction; a rounded-down round-trip (base to quote to base) never exceeds the original amount | y | - | - | No value creation from rounding |
| Zero input amount or zero numerator price returns 0; a zero denominator price reverts | y | - | - | Fails closed instead of minting or silently zeroing; a zero share denominator in `calculatePriceAssetPerShare` is the consumer's responsibility per natspec |
| Conversions are monotone non-decreasing in the input amount (fixed prices, decimals, rounding) | y | - | - | |
| With equal decimals and unit price, every conversion is the identity | y | - | - | |
| Results are range-checked: a result exceeding uint128 reverts rather than truncating | y | - | - | Full-precision mulDiv + checked cast |
| Decimal normalization assumes decimals <= 18, enforced at registration on both hub and spoke | y | - | - | |

### Utils (`src/core/utils`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Envoy: both entrypoints are ward-gated (MessageDispatcher/MessageProcessor only); a non-ward can never originate a `fromHub`/`fromSpoke` call | y | - | - | Targets authenticate `msg.sender == envoy`, so Envoy's gate is the whole chain of custody |
| Envoy: stateless, exact-value forwarding: every wei received is forwarded in the same call, so it retains none of the ETH sent through its calls; `poolId`, payload, and `(centrifugeId, sender)` attribution reach the target unmodified | y | - | - | `sender` is unauthenticated attribution by design (matches the Spoke exception); force-sent ETH is stranded but unused |
| ContractUpdater: `trustedCall` is ward-gated and stateless; targets always see `msg.sender == contractUpdater` | y | - | - | The immutable anchor legacy spoke targets bind to |
| ContractUpdaterForwarder: `fromHub` is callable only by the Envoy and rejects ETH; `unwrap(wrap(...))` round-trips and the forwarded call preserves `(poolId, scId, target, inner)` exactly | y | - | - | The wrap shape must stay in sync with `StdHubManifest._checkManagerCall` |
| ContractUpdaterForwarder: adds no authority; it can only reach targets that already trust ContractUpdater, and only via a hub-authorized `managerCall` routed through the Envoy | y | - | - | |
| BatchedMulticall: transient `msgSender`/`msgValue` are set for the duration of a batch and cleared after; nested batching is rejected | y | #278 | - | Verified as part of the Spoke FV run |

### ID types (`src/core/types`)

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| `PoolId`/`AssetId`/`ShareClassId` encode/decode round-trip: `centrifugeId` and counter/index recover exactly, and construction is injective | y | - | - | The `AssetId` counter (uint64) can never carry into the `centrifugeId` bits |
| A `PoolId` with a non-zero `centrifugeId` is never null; `ShareClassId`s embed the full pool id, so they are globally unique across pools and non-null for existing pools | y | - | - | FV covers uniqueness at the ShareClassManager level; this is the type-level statement |
| ISO-4217 asset ids have `centrifugeId() == 0`, disjoint from every chain-registered asset id | y | - | - | Zero-home ids are rejected as message sources (see MessageLib) |
| `AccountId` namespaces never collide | n | - | - | `withCentrifugeId(n, i) == withAssetId(AssetId(n), i)` whenever an ISO-4217 code numerically equals a `centrifugeId`; safe only by caller convention, so consumers must not mix both constructors within one pool's account space |
| `RequestId` imposes no structure at the type level; any packing convention must guarantee distinct vaults yield disjoint id ranges | y | - | - | The property belongs to the request manager's packing; stated here so it isn't lost |

## Vaults specification

`src/vaults` is the Vault Development Kit, specified row by row in
[`src/vaults/SPECIFICATION.md`](../src/vaults/SPECIFICATION.md) with the same conventions as this
document (a `Tests` column stands in for `Fuzz`). It composes with the core and token properties
here and does not restate them.

The stack, at the altitude of the core sections above:

* **`Vault`**, one per `(pool, share class, asset, variant)` position and deployed by **`VaultFactory`**, is a
  single ERC-4626 / ERC-7540 / ERC-7575 vault serving both instant and async deposits and redeems. It
  holds all investment state: async requests are contributions to pro-rata buckets
  (`BucketLib`), folded into a per-controller claimable ledger (`BucketLib.foldInto`, through `HorizonLib`; `VaultPricingLib` holds the conversions).
* **VDK plugins** plug issuer behavior into fixed slots without core changes: a request policy
  (bucketing and flush timing), an optional instant policy (instant capacity and fees,
  `ReserveInstantPolicy`), an optional liquidity route (third-party instant liquidity,
  `BasinLiquidityRoute`, `VaultLiquidityRoute`), an optional settlement observer, and the oracle
  (`SpokeOracle`, hub-notified prices with freshness and skew bounds). Vault actions are gated by the
  share token's hook, through the role checks the vault asks of it (`IRoleHook`).
* **`VaultRequestRouter`**, a per-network singleton registered as the pool's spoke-side request
  manager, carries flushed buckets to the hub and settlement callbacks back to the vault.
* **`OrderBook`** is the hub-side request manager: each request is an independent order keyed by its
  vault-namespaced request id, auto-approved on arrival and fulfilled or cancelled by the manager
  with explicit amounts and prices that the pool's hub policy bounds. **`FeeRequestManager`** is the
  reference wrapping manager that derives a fee-adjusted net amount and forwards through
  `Hub.managerCall`.

## Token specification

Share token and transfer hooks in `src/token`.

| Invariant | Holds | FV | Fuzz | Notes |
|---|---|---|---|---|
| Transfers to or from frozen investors revert (`transfer` and `transferFrom`) | y | - | e2e `token_transfer`, `token_transferFrom` | Supply conservation is stated once, in the system-level section |
| Transfers to non-members who are not endorsed revert | y | - | e2e `token_transfer`, `token_transferFrom` | |
| System addresses never receive investor share tokens, and transfers from endorsed system contracts are blocked by the hook | y | - | e2e `property_system_addresses_never_receive_share_tokens` | Asserted over the protocol's own flows. The hook admits endorsed contracts as recipients by design, so an investor can still send shares to one; the clause on transfers from endorsed contracts is not fuzzed |
| Fuzz-harness sentinel: an actor can reach a non-zero share balance | y | - | e2e `testTheFlowsAreReachable` | Replaced by a reachability test that drives every flow once and asserts it went through, so a setup change that silently turns an action into a revert fails rather than leaving the suite green and empty |
