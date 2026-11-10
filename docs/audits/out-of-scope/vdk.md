Out-of-scope list for the Vault Development Kit (VDK: `src/vaults` and the vault actions in `src/token/hooks`), the vaults v2 redesign, for audits, reviews and the bug bounty on the release that carries it. It states the assumptions a finding may rely on, and complements, without restating, [`src/vaults/SPECIFICATION.md`](../../../src/vaults/SPECIFICATION.md) (the normative behaviour, one row per property) and [`src/vaults/README.md`](../../../src/vaults/README.md) (the design).

This file is an extension of [`cantina-bug-bounty.md`](cantina-bug-bounty.md), the protocol-wide list, and is read together with it. It lists only what that list does not already cover: nothing here narrows it, and what it excludes (trusted pool managers, late or reordered messages, gas accounting, adapter sets, subsidy spam, decimals, router value and custody, and the rest) applies to the VDK in full.

A finding that needs a trusted party or a pool-chosen component to misbehave is out of scope, unless it breaks one of the isolation and bounding guarantees listed under [What stays in scope even when a component misbehaves](#what-stays-in-scope-even-when-a-component-misbehaves). Everything under [Out of scope](#out-of-scope) is accepted risk by design.

## What stays in scope even when a component misbehaves

The trust model has a few guarantees that hold whatever a pool chose. These are in scope, because they are what keeps one pool's choices from reaching anyone else:

- A pool-chosen component, or a pool's manager, cannot move or lock **another pool's** funds, nor corrupt state keyed to another pool or vault (SPECIFICATION, `CrossPoolIsolation`).
- A misbehaving component cannot take **protocol-level** resources: a ward, the shared singletons' state for other pools, or Root.
- The bounds the code claims to enforce hold: a fee is strictly below the amount on `deposit` and `redeem` (on `mint` and `withdraw` the vault does not bound a policy's fee), a request id belongs to its vault, a callback is accepted only from the pool's request manager.
- An **untrusted** party (investor, operator, keeper, relayer, anyone transferring a request or calling a permissionless function) cannot extract value, lock funds, or corrupt ledgers when the pool's components are honest.
- The shipped implementations (`PerInvestorPolicy`, `PerRequestPolicy`, `PerPeriodPolicy`, `ReserveInstantPolicy`, `SpokeOracle`, `VaultLiquidityRoute`, `BasinLiquidityRoute`, `OrderBook`, `FeeRequestManager`, `VaultRequestRouter`) are correct against their own interfaces and spec rows, under their documented configuration.

## Out of scope

### The specification and the standards

- Properties that the specification records as non-guarantees (rows marked `n`), and the configurations its "Deployment constraints" section requires of a pool, are out of scope. A report that shows harm beyond what the row states is in scope. The three constraints are: a share class whose registrar lacks `authTransferFrom`, an instant lane run without a price-freshness bound or a round-trip spread, and a shared liquidity route whose venue liquidity is not partitioned between pools.
- The deviations from ERC-4626, ERC-7540, ERC-7575 and ERC-8161 that the specification lists are out of scope, so integrators must not rely on `max*`, previews, `claimable*Request`, `totalAssets` or the share token's ERC-7575 pointer beyond what it states.
- Design issues in a draft standard itself (ERC-8161), and ambiguities in ERC-4626, ERC-7540 or ERC-7575 where the specification records the choice made.

### Pool-chosen components

A pool chooses its request policy, instant policy, liquidity route, oracle, settlement observer, the share token's hook and the OrderBook's request observer, and the stack calls them plainly: no gas caps, no fallback values, no ceilings over their answers (SPECIFICATION, "Trust in pool-chosen components"). A component that reverts, burns gas, returns wrong or hostile values, re-enters the vault, mutates state or blocks settlement or claims harms that pool's own users only. These are **not** findings:

- a custom or buggy policy, route, oracle or observer, including one that reverts forever, returns inflated capacity, leaves requests unflushable, returns a negative fee that names an investor as the rebate source, or a rebate larger than the amount it tops up;
- a share token hook that is swapped or misconfigured and blocks claims or transfers;
- reentrancy from any of those components, including mid-callback reentrancy from the observer, a route's `forward`, or a token hook;
- `VaultPlugins` in a `DeployAndLink` payload that are not the canonical singletons (the controls are the hub policy delay and sentinels);
- a vault left unusable by the pool's choice of components, since policies are fixed at construction.

A component of one pool that harms another pool or the protocol is in scope.

### Pool managers, pool configuration and hub inputs

Pool managers are trusted within their own pool, as `cantina-bug-bounty.md` states. In the VDK that includes:

- fills, partial fills and cancellations of orders, at prices and fees the manager chooses (within the bounds `StdHubPolicy` enforces). Fill amounts, prices, net and gross amounts, rebates and cancellations are inputs, and a fill that over-issues, misprices or settles against cash the escrow does not hold is a manager or policy error. A settlement that reserves more than the escrow holds leaves withdrawals, instant redemptions and deposit cancellations on that holding reverting until the pool tops up the escrow or approves the pending deposits;
- changing instant terms (fees, retained fees, reserve cap, allowlists), the fee manager's fee, routes, limits, the oracle's pause, the router's extra gas, or the share token's hook through the Envoy. The values a pool configures are its own responsibility, whatever bounds they were meant to give: fees, capacities, reserve targets, windows, notice periods, the fold horizon, allowlists, route lists, credit lines and, for a pool that deploys its own oracle, its `maxAge` and `maxSkew` (the canonical `SpokeOracle` is shared, with both fixed at deployment), including values of zero or `type(uint128).max` that switch a bound off;
- raising a fee, or pausing, immediately before an investor's transaction;
- linking, unlinking, granting or revoking the spoke manager role, and moving the pool's own assets through the balance sheet;
- freezing or de-membering investors of the pool's own share class.

Findings are in scope when a manager can exceed those powers (reach another pool, bypass `StdHubPolicy`'s classification, escape a bound the contract states).

### Assets

Assets are assumed to be plain ERC-20s: non-rebasing, no transfer fee, no transfer hooks or callbacks, not pausable or blocklistable (SPECIFICATION, the asset rows). A vault notes the requested amount and accounts before it pulls on the instant paths, so asset onboarding has to rule such tokens out. ERC-6909 and ERC-721 assets are unsupported. Behaviour with any other token is out of scope.

### Third-party venues and shared singletons

- The solvency, behaviour and withdrawal terms of Basin, of an underlying vault behind `VaultLiquidityRoute`, or of any other venue a route points at, beyond how the route measures delivery and books the result. The liquidity, fees, prices and credit of a venue are the routing pool's risk, bounded by its position in it, and a draw that cannot be met reverts.
- Loss of funds a route has already drawn or deployed into a venue, and the Basin liquidity provider's own key management.
- A top vault's holders can redeem at its own price after the underlying's price falls and before the top price follows, and the underlying's exit fee falls on the routing pool.
- The hub books a Basin draw as a liability only once the pool initializes the liability holding, and the surplus a venue returns beyond a draw is a donation to the escrow.
- The routes, the oracle and the shipped hooks are one contract per network and serve every pool, so what one pool grants them reaches every pool that uses them. An underlying pool consents to each routing vault by name, but a venue's liquidity is not reserved per vault: every vault enabled on one route draws on the same venue.

### Economics and market behaviour

- Arbitrage of the instant lane against a stale or jumped price, where the pool chose a small or zero spread. The instant lane trades at the price the oracle last had notified, within `maxAge` and `maxSkew`, and an asynchronous fill uses the hub's price, so what a trader gains from the gap while the spoke price lags is out of scope unless the pool quotes a round-trip spread.
- Cash that a manager sends to the escrow to fund an asynchronous redemption counts as available balance until its settlement callback reserves it, so instant redeemers can take it first.
- Front-running, sandwiching and other MEV against price updates, fills or configuration changes.
- Bank-run dynamics, escrow or venue illiquidity, and the choice of capacity limits.
- Griefing that costs the attacker more than the victim, or only the attacker's own pool. An actor the pool did not choose can add state only for itself, at the cost of its own gas, and the cost to a victim is out of scope when the victim is left whole by one further call, such as a one-wei request that costs the pool a cross-chain message. The issuer constrains who can request and how much through the share token's hook, an allowlist or the request policy.
- Temporary reverts that a manager or governance action clears without the cooperation of the actor who caused them are delay and not loss, such as a claim that a hook or a paused oracle refuses until the pool acts.

### Rounding and dust

A vault accounts for settlements in the vault's favour, and the remainders stay in the system. That means up to one unit per contributor of a shared bucket per settlement, a slice whose counter-unit floors to zero, redemption dust, the one-unit drift between a vault's counter amounts that follows, and `max*` views at a capacity of a few units.

### Configuration and registration

Configuration is fixed at construction and there is no setter. A vault left linked after a replacement and a settlement that a callback cannot deliver to an unlinked vault are corrected by deploying another `variant` or by the pool relinking.

### The router

Vaults, hooks and policies see the router as the caller, and it is exempt from membership hooks as an endorsed contract, so a pool that gates a lane by caller does not allowlist it. The router does not enforce a holder's own roles on the caller's behalf except where its interface says it does.

### Off-chain and operational dependencies

- Keepers: the system relies on someone calling `foldRequest` and `flushRequest`. Availability and gas policy of keepers, relayers and SDKs are out of scope. A call that stays permissionless and correct is in scope.
- Frontends, SDKs, indexers and subgraphs, including indexer correctness against the events.
- The accuracy of non-normative documents: `docs/vaults-policies.md`, architecture diagrams and design notes.

### Migration

- Migration from the v1 vaults and how v1 vaults interact with VDK hooks.

### Other

- `test/**`, mocks, `src-ir/`, `script/anvil`, `script/testnet`, and unchanged files under `src/` outside `src/vaults` and the VDK's changes elsewhere.
- Informational findings, gas optimisations, style, NatSpec typos, and generic "a trusted role can do X" centralisation notes. They are welcome but not eligible for a bounty.
- Stale comments in frozen code that name deleted v1 contracts.

### Specific items

* Known issue: sibling vaults on one (share class, asset) can together reserve more than the escrow holds, because `Vault._reservePayout` counts only its own reservation and core `Escrow.reserve` does not bound the total (specification, "Parallel vaults on one position cannot together reserve more than the escrow holds"). No funds move wrongly: while the reservations exceed the holding, every withdrawal of it waits, the earlier claimants' included, since `Escrow.withdraw` requires the total to cover every reservation, until the pool tops up the escrow or a deposit leg settles.
* A sponsor a pool allowed on a vault's instant policy can credit any controller, including the zero address, the router or a fund-of-funds route, and a pending or claimable position it credits holds that controller's instant lane in async until it is settled and claimed, as the controller's own request would. Sponsors are the pool's trusted parties, and nobody else can credit a controller it does not act for. Without an instant lane nothing routes on a pending position, so any caller may credit any controller, as in v1.
* On a vault without an instant lane, a pushed position is claimable once it settles, through the horizon fold or the permissionless `foldRequest`. A full horizon evicts the oldest position even while unsettled when the controller's own request needs the slot. An unbatched bucket folds as it settles, but a batch past the horizon needs a `foldRequest` before a claim sees it, so `PerPeriodPolicy`'s window buckets are the ones exposed to this. Without an instant lane anyone may also request for any controller, but a position the controller did not submit takes a free slot only and never evicts one of theirs, so a stranger cannot push the controller's positions out of its horizon; a batched gift that finds no slot waits for `foldRequest`, which also restores the claims and the `max*` views.
* The router checks the bridger role and the bridge limits against itself and not the holder, so once a pool grants the router the role, every holder can bridge through it. The router also pulls the share token the vault reports while the spoke burns the registry's token, so a vault registered through a pool's own factory can name another pool's token.
* On a vault without an instant lane a request transfer needs nothing from its recipient, as ERC-8161 specifies, so anyone holding a pending position can move it onto any controller, a contract included. It takes a free slot in the recipient's horizon and never evicts one, so when no slot is free a batch's settlement waits for `foldRequest`; the recipient loses nothing.
* The hook treats the escrow of every pool as a member of every share class in every role, so a holder who is not a member can move a restricted token into another pool's escrow and exit through that pool's vault.
* The horizon tracks each controller's recent positions up to the vault's fold horizon, and a full horizon evicts the oldest position to make way for the controller's own request, even if it is unsettled (never one of their open buckets). It still counts as pending, and an unbatched one folds as it settles unless that fold is deferred (below), but once a batch settles a claim does not see it until someone calls `foldRequest`.
* * A vault's settlement callbacks need only the request manager and not a link, and the share token's hook cannot tell the vault's call from a third party's forged role check: both are harmless with the shipped components and recorded in the specification.
* An investor has no cancel of their own: cancellation is order-level and the pool's.
* A request id is not unique over a vault's lifetime: `PerInvestorPolicy` reuses a retired sole-owner id, so an integrator keying a secondary market on `requestId` alone must key on the controller too.
* `VaultFactory.deploy` is permissionless, so anyone can deploy a vault for any pool at its predictable address. It acts for no pool until that pool links it, and the registry lists only linked vaults.
* A vault is registered under the pool that sends `DeployAndLink`, and `SpokeRegistry.registerVault` does not ask the factory whether it built the vault, so a manager of one pool can register a vault that another pool deployed through the permissionless `VaultFactory.deploy` and the other pool deploys another variant (specification, "A vault address built for one pool cannot be registered by another").
* `FeeRequestManager` applies the fee in force when a fill executes and not when the request was made, and investors have no cancel of their own, so a fee change that the hub policy delays still reaches pending requests, bounded by the policy's maximum fee. A fill whose fee rounds its net to zero is rejected and can only be cancelled.
* A deposit's reservation is keyed by the request's id, which a sole owner's later top-ups share, so after a manager unlocks a deposit early its approval can release the cash of a top-up that is still pending.
* TODO: `StdHubPolicy` cannot force a pool's managers through `FeeRequestManager` instead of the `OrderBook`. Its allowlist confines a caller to selectors, and `FeeRequestManager` asks the policy as the original manager with the same `managerCall` selector, so a manager who may send `managerCall` may also send a direct `OrderBook` fulfillment with its own prices and net, and one who may not cannot use the wrapper either. A per-target check (an `allowedTarget` per caller, so `OrderBook` is reachable only through `FeeRequestManager`) would close it and is not built.
* A fold credits the claimable ledger (`BucketLib`) into `uint128` counters, and a fold whose credit would push one past `type(uint128).max` is deferred: it changes nothing, the position stays unfolded and counts as pending, and the controller's claims and views keep working. Once the ledger is claimed down a later fold credits it, a claim's while the position is in the controller's horizon and `foldRequest` once it has left it. With the default horizon of 1 the controller's next own request evicts it, so from then on only `foldRequest` credits it, an unbatched bucket's included, since its fold at settlement was the deferred one. A position whose sender's fold is deferred cannot be transferred until it folds (`FoldDeferred`). At ordinary share prices it takes on the order of 256 unclaimed fills of a maximal size, fewer only when the share price sits near the D18 minimum, and a settled window pushed onto a victim under `PerPeriodPolicy` can do it. Saturating the add would distort the ledger's pro-rata ratio and overpay assets per share, and widening the field costs a slot, so the fold waits instead.
* A refund of a cancelled deposit's assets to a receiver other than the controller is a `RedeemClaim`, which the payout role refuses for an endorsed contract under `FreelyTransferable` and `FullRestrictions`, where v1 let an endorsed router receive it. The controller can take the refund to itself (`DepositRefundClaim`) and forward it. It stays because the payout role is what keeps assets leaving the pool from reaching a non-member.
* A request's refund goes to the controller the request named and not to the owner who funded it, so a hook whose `exit` is looser than its `transfer` lets that controller receive shares it could not have been sent. The shipped hooks are not affected, since the controller had to pass the request's bar when it was made, and a pool with such a hook should allow no sponsors.
