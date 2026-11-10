# Vault Development Kit: what is and is not supported

This document records what two surfaces of the same pipeline can and cannot express: the
spoke-side VDK plugins that shape how a request forms, and the hub-side request manager that
prices and settles it. Both were validated against dozens of candidate implementations drawn from
real financial-product mechanics (TradFi fund liability management, regulated-fund plumbing,
structured products, DeFi integrations), deliberately ignoring what the protocol supports
today. For each behavior it records the mechanism that expresses it, or why it is deliberately
out of scope.

The **spoke side** is the six VDK plugins: the five slots of each vault (`IRequestPolicy`, `IInstantPolicy`,
`ILiquidityRoute`, `ISettlementObserver`, `IVaultOracle`) plus the share token's own hook
(`IRoleHook`); see `src/vaults/README.md`
("Composition idioms") for the conventions they rely on. The **hub side** is the
request manager (the OrderBook engine and its wrapper managers) and the pool policy that bounds them. The sections
run spoke-side first, capped by three worked staking-token examples, then cross to the hub side.

## Contents

**Spoke side: VDK plugins**

- [The three levers](#the-three-levers)
- [Request policies (`IRequestPolicy`)](#request-policies-irequestpolicy)
- [Instant policies (`IInstantPolicy`)](#instant-policies-iinstantpolicy)
- [Liquidity routes (`ILiquidityRoute`)](#liquidity-routes-iliquidityroute)
- [Settlement observers (`ISettlementObserver`)](#settlement-observers-isettlementobserver)
- [Vault oracles (`IVaultOracle`)](#vault-oracles-ivaultoracle)
- [Share token restrictions (`IRoleHook`)](#share-token-restrictions-irolehook)
- [Redemption models and the request manager](#redemption-models-and-the-request-manager)
- [Worked examples: three staking tokens](#worked-examples-three-staking-tokens)

**Hub side: OrderBook**

- [Hub-side execution: OrderBook, wrappers, and the pool policy](#hub-side-execution-the-orderbook-engine-wrapper-managers-and-the-pool-policy)
- [Why a wrapper, not a hook](#why-a-wrapper-not-a-hook)
- [Worked hub-side examples](#worked-hub-side-examples)
- [Follow-ups outside this surface](#follow-ups-outside-this-surface)

## The three levers

Most candidate implementations that look blocked at first sight are not, because of three
properties of the design:

1. **Composition**: one contract may fill several `VaultPlugins` slots. A request policy sees
   fulfillments by also being the settlement observer; an
   instant policy sees the async lane by also being the request policy; an observer knows the
   controllers behind a shared bucket by recording them in `onRequest`.
2. **Public state**: hooks pass identity and amounts only, but plugins read everything else
   themselves: prices (`vault.oracle().prices`), staleness (spoke registry timestamps), escrow
   liquidity (`spoke.availableBalanceOf`), route headroom, share supply, per-controller
   positions. "% of NAV" and "% of holdings" rules need no hook support.
3. **Hub-side fulfillment flexibility**: partial fills are native (`pending` decreases
   incrementally, claims convert pro-rata against exact totals), so pro-ration, carryover, fill priority,
   netting, and multi-realization payouts are hub decisions requiring no spoke primitive. The
   96-bit localId rides to the hub inside the requestId, so a bucket is nameable hub-side; the
   id is allocated by the vault, so a bucket tag (window, tier, penalty flag, call number)
   lives in the policy's own storage against the key it answered, which the vault's `keyOf` maps
   each id back to. A policy that tags single requests answers a fresh key of its own for each
   rather than the zero key, which carries no tag.

## Request policies (`IRequestPolicy`)

Settled slices reach a controller's ledger when they are folded: by the vault at settlement for a bucket the policy
did not batch (every bucket of the two non-batching policies), by a claim for the controller's
vault's `foldHorizon` latest positions per side (unless configured, the request policy's `maxOpenBuckets`), and by anyone
through `foldRequest` for the rest. When a request opens a new batch on a side, the vault asks the batching policy's
`isClosed` about the side's previous batch and flushes it if it is closed and holds queued requests; one still open
waits for `flushRequest`.
On a vault with an instant lane, only the controller, its operator or a sponsor the instant policy accepts can open
or receive a position for a controller (`canCredit`, see Instant policies); without one, anyone may, as in v1, since
nothing routes on whether a position is pending. A full horizon makes way by its oldest.

Supported, as request policies alone or composed with other plugins:

| Behavior | Mechanism |
|---|---|
| Notice periods | bucket per execution date, `isClosed` gates on maturity; a transferred position stays in its bucket, so the transferee inherits the notice date |
| Fund-level redemption gates (% of NAV per period, carryover) | period buckets spoke-side; pro-ration and carryover are hub-side partial fulfillment |
| Per-investor gates (redeem ≤ Y% of holding per period) | `onRequest` reads the controller's stake in the window's bucket from the vault (`bucketOf`, `contribution`) and the holding from the token, keeping no records of its own; a transfer moves the stake on the vault, so a transferee cannot exceed the gate with a position moved in. Settled-vs-requested via composed observer |
| Lockups / cliffs / anniversary windows | issuance timestamps from the composed observer (async) or `onInstantDeposit` (instant); a lockup on share transfers needs the token's transfer hook (`ITransferHook`), since `IRoleHook` reaches only the vault's role checks; penalty tag recorded against the request's key in policy storage for hub-side fees, read back through `keyOf` |
| Cash-funded capital calls | commitment = escrowed request; the hub draws per call via partial approval/fulfillment |
| Tender offers | window gating + `isClosed` on board confirmation; tier sub-buckets filled in hub-chosen order |
| Capacity rights / soft closes | reservations in policy storage; capacity released on settled redemptions via composed observer |
| Dealing calendars (cutoffs, holidays, asymmetric cadence) | pure time arithmetic; a per-side `depositNotice` or `redeemNotice` on `PerPeriodPolicy` gives a cutoff before each close, or a minimum wait; permissionless `flushRequest` + keeper seals windows; an investor with more unsettled windows than the vault's `foldHorizon` (unless configured, `maxOpenBuckets`: 1 without a notice) needs a keeper `foldRequest` for the older ones |
| Netting deposits against redemptions | hub-side: both buckets settle at one NAV |
| Side pockets (stressed redemptions paid per realization) | hub fulfills the liquid portion promptly, the rest per realization event, at each event's price |
| GP consent / ROFR on pending-request transfers | the share token's role hook, which the vault asks on every transfer (`DepositRequestTransfer`, `RedeemRequestTransfer`) with both holders and the amount; approval registry in the hook, keyed by the vault |
| Anti-churn cooldowns | delivery timestamps via composed observer reading `block.timestamp` in `onSettle` |

Not supported:

- **User-initiated cancellation**: by design. Pending requests are irrevocable spoke-side.
  Cancellations are manager-initiated hub-side (the `OrderBook` `Cancel` action), arrive as
  `CancelledDeposit`/`CancelledRedeem` callbacks carrying both a gross and a net amount, and are
  refunded on the opposite side (cancelled deposit assets via `withdraw()`, cancelled
  redeem shares via `mint()`), to the controller itself even after it has lapsed from a memberlist (`DepositRefundClaim`, `RedeemRefundClaim`). The refund goes to the controller the request named, not to the owner who funded it, so it is as safe as that controller was when it passed the request's membership check. Policies react through the composed observer's `Settlement`, which carries both
  `cancelledGross` and `cancelledNet`, so the retained fee is their difference.
- **Unfunded commitments**: `requestDeposit` moves assets to escrow at request time; a
  commitment without cash cannot be registered.
- **Request splitting and bucket editing**: no re-bucketing after a calendar change, no
  expelling a defaulted contributor, no atomically linked bucket pairs.

ERC-8161 transfers, by contrast, are supported at the **contribution level** (the single
pro-rata settlement model made every request a bucket contribution): `transferDepositRequest`/
`transferRedeemRequest` fold the sender's earned slice into their own ledger, then move only the
unsettled remainder and its folded snapshot to the new controller. This works for a contributor
inside a shared bucket too, and `PerPeriodPolicy` supports it: buckets are keyed by window and side
rather than by controller, so a transfer needs no policy state and the bucket's `total` is untouched.
`PerInvestorPolicy` declines transfers, because it resolves every later request from a controller to
that controller's one recorded bucket, and so does `PerRequestPolicy` when deployed with transfers off. Whatever the
policy allows, a vault with an instant lane requires the caller to act for the transferee too, or the sender to be a
sponsor; without one a transfer is a plain ERC-8161 push. The position then enters the transferee's horizon.

## Instant policies (`IInstantPolicy`)

The hooks receive `(vault, sender, receiver, assets, exactOut)` where `sender` is the vault's caller
(the payer on deposit, the share owner on redeem); deposit capacity is keyed by receiver and
redeem capacity by owner, matching ERC-4626 `maxDeposit(receiver)`/`maxRedeem(owner)`. A policy
that gates on the caller (`ReserveInstantPolicy`'s per-lane allowlist) can only enforce in the
mutating hooks, which is where the caller is visible. Its deposit view quotes the lane and stays
caller-agnostic: a view keyed by the receiver cannot see the caller, and gating on it would close the lane
for the investor a front-door router deposits for. Its redeem view is keyed by the owner, who is the caller on
every instant exit, so it reports nothing for an owner off a gated redeemer allowlist.

Fees are signed, and the recipient decides where a positive fee goes:

- **Positive, with a recipient:** paid to it.
- **Positive, with no recipient (`address(0)`):** retained in the escrow for the existing holders, backing no
  shares. The vault's `InstantFees` event reports it as `retainedAssets`, with the caller, the shares traded and
  the prices of the trade.
- **Negative (a rebate):** pulled from `feeRecipient`, which is then the fee *source* and must have approved the
  vault. It is folded into the conversion on deposits and paid on top of the payout on redemptions, so a rebate
  is funded by that pot, never by the pool, and it needs a non-zero recipient (`InvalidFeeRecipient`). No shipped
  policy rebates, previews clamp a rebate to zero (so `previewDeposit` understates), and a rebate larger than
  the amount it tops up panics instead of reverting cleanly.

One trade has one fee, so a manager fee and a holder spread cannot be taken together in the same trade. The
way to get both is to name a splitter contract as the recipient: a balance sheet manager with a permissionless
`split()` that pays the manager's share and returns the rest to the escrow. It runs after the trade, not inside
it (see `src/vaults/ARCHITECTURE.md`, "Where an instant fee goes"). The spread is always charged on the gross: on
the exact-out entrypoints (`mint`, `withdraw`) `exactOut` tells the policy it was handed the net, which
`ReserveInstantPolicy` grosses up at its rate, so `withdraw(x)` and `redeem(previewWithdraw(x))` cost the same.

The vault decides which calls reach these hooks: a call is instant only when the caller is the controller and
has nothing claimable and nothing pending on that side. Operators can only claim, and the 3-argument
`deposit` and `mint` never take the instant lane. Pending is the controller's total, so a sponsor's pending position
closes the lane like an own request, and a position evicted from the fold horizon keeps holding it. The routing decides
a call's lane, not what a holder may do across calls, so a rule that must hold (a round-trip guard, a per-period cap)
gates in the policy, composed with the request policy.

Supported:

| Behavior | Mechanism |
|---|---|
| Rolling flow limits (% of NAV per window) | local-chain NAV read as supply × oracle price (pool-wide caps are hub-side, below); window state in policy storage; views simulate the roll |
| Eligibility-gated deposits (Merkle proof, caps) | a front-door router is the sole deposit caller; `ReserveInstantPolicy`'s `gatedDeposit` allowlist rejects any other `sender` and the request policy rejects async deposits, so there is exactly one issuance path; the router holds the mutable eligibility root, the caps and the pause, and the share stays the canonical composable token (USHPi, the first worked example below). Under the full-restrictions and freely-transferable flavors of `ShareTokenHook` the router is the `controller` of `InstantDeposit`, so it must be a member or endorsed, and the receiver must be a member for the issuance leg |
| Utilization-based fee curves | mutating hooks track cumulative consumption, so split transactions don't evade them |
| Stale-price / price-jump breakers | policy reads `vault.oracle()` and registry price timestamps; jump memory updated on mutating hooks + keeper poke |
| 2a-7-style liquidity fees and gates | a custom policy with keeper-fed thresholds via `fromHub` config (`ReserveInstantPolicy` takes fixed bps only); a fee that stays in the fund is a positive fee with no recipient; async-lane gating by composing the request policy |
| Per-identity tiers and caps | payer visible via `sender`; tier data readable from the compliance transfer hook |
| Trading calendars (market hours, holidays) | pure time arithmetic; per-direction windows |
| Swing pricing (penalties *and* credits) | net-flow-conditioned signed fee. Penalties are retained for the holders (zero recipient), or, to be self-balancing, paid to a funded pot that also pays the credits as negative fees. A retained penalty cannot fund credits, since a rebate needs a funded recipient that has approved the vault |
| Deposit / liquidity-provision rebates | negative fee on a custom policy: `feeRecipient` doubles as a funded fee source; on deposits the vault pulls the rebate into the escrow and folds it into the conversion (shares stay asset-backed), on redemptions the source pays the receiver directly; resting holders are never diluted |
| Decaying dutch exit fees | manager-triggered auction mode via `fromHub`; fee lerps to zero over the window |
| Reserved zero-fee capacity for liquidators | per-controller carve-outs; the vault already clamps promises to escrow + route headroom |
| Per-period subscription caps, AUM hard caps | local-chain AUM = supply × oracle price; pool-wide caps are hub-side; async subscriptions counted via composed request policy |
| CDSC / loyalty exit fees | instant lane: the instant policy; async lane: a hub-side wrapper (the two do not share a recipient mechanism); lots via composition; secondary transfers via a registry shared with the issuer's transfer hook |
| Same-block round-trip guards | last-deposit/redeem tracking per identity in policy storage |

Not supported:

- **Bonuses drawn straight from the escrow**: the vault never draws a rebate from the escrow, which could not
  be bounded and would dilute resting holders. A pool funds a bonus by having its balance sheet manager top up
  the fee source, under pool policy.
- **Changing the conversion price**: pricing is the oracle's; policies only apply signed fees
  around it.
- **Sybil-resistant identity**: per-address tracking is evadable by wallet-splitting unless
  the policy shares an identity registry with the compliance transfer hook.

## Liquidity routes (`ILiquidityRoute`)

`available` is advisory (overstating it reverts the redeem, never loses funds) and must not
revert, since the ERC-4626 `max*` views reach it; `provide` is synchronous and all-or-nothing; `forward`
is the opposite leg, offering freshly-escrowed deposits to the venue, and a route that forwards
nothing is a valid no-op, but a `forward` that reverts blocks instant deposits and `approveDeposits`, and with it
the hub settlement. The cost of provided liquidity is priced as an exit fee by a
composed instant policy. Routes that monetize pool assets receive them through a
balance-sheet manager parking/approving funds under pool policy, never through protocol
permissions. The vault notes every draw as a plain inflow, so a route whose draw is a loan books
the debt itself, as liability `AccountingToken`s deposited into the escrow in the same transaction
(`BasinLiquidityRoute`), which keeps NAV per share unchanged by the draw.

A route must be set up before it works: `BasinLiquidityRoute` and `VaultLiquidityRoute` need the manager role
on the pool (and Basin the accounting token's minter role and a spoke policy that admits it); without them
`available` reads zero and instant exits revert. `VaultLiquidityRoute` also needs the underlying pool's consent to
each routing vault by name, since the route is one controller per underlying vault shared by every pool. The vault caps nothing a route does, except that
`VaultLiquidityRoute` bounds each underlying quote at `QUOTE_GAS` (400k), the one place the stack caps gas; capacity is also clamped to what converts.

Supported:

| Liquidity route | Mechanism |
|---|---|
| Pre-collateralized RFQ quote books | MMs escrow cash with signed quotes; `provide` fills best-price-first |
| Committed credit lines | draw/repay against a pre-funded facility, each draw booked as a liability until repaid; interest and standby fees are hub-side pool expenses |
| Fund-of-funds exits | `BasinLiquidityRoute` directly on the fund-of-funds vault (one hop, the pool owes the venue), or `VaultLiquidityRoute` redeeming an underlying vault through its instant capacity (`withdrawCapacity`, `previewRedeem`); when that vault itself has a route the exit has two hops and the underlying owes it |
| Staked insurance / underwriter pools | stakers pre-fund and earn a premium; write-offs are the route's own governance |
| Waterfall routers | meta-route composing child routes by priority with per-rung caps |
| Cross-vault liquidity sharing | donor pools' surplus parked in a shared route by their balance-sheet managers |
| Lending-market borrows, repo | the pool's balance sheet manager (BSM) parks pool collateral with the route; borrow cost priced by a composed instant-policy fee |
| Tokenized-MMF instant redemption hops | BSM parks the MMF tokens; asset swap, so the receivable is zero |
| DEX routes | BSM-parked assets; slippage charged to the exiting user via a composed fee |
| Deposit-against-redemption crossing | needs no route: instant deposits raise the shared escrow's available balance directly |

Not supported:

- **Asynchronous provide**: T+hours facilities (bank sweeps, real repo desks) participate
  only up to a pre-funded on-chain float; larger capacity belongs to the async redeem lane.
- **Partial fills and cost returns**: `provide` fills exactly or reverts, and reports no
  cost; deliberate, to keep `available` advisory and pricing in the instant policy.
- **Flash-recovered JIT liquidity**: recovery inside `provide` would need pool-asset seizure
  or a tradable receivable primitive; neither exists.

## Settlement observers (`ISettlementObserver`)

`onSettle` receives `(vault, requestId, isDeposit, settlement)` once per settlement, after it is applied: a fill's
`assets` and `shares`, or a cancellation's `cancelledGross` and `cancelledNet`, the figures of the vault's
`BucketSettled`. It carries no timestamp: the observer reads `block.timestamp`, which is the spoke's
delivery time of the callback, not the hub's pricing time (that is in the hub `OrderBook.Fulfill` event), and
for a remote spoke or a retried message the two differ. A revert fails the whole `SettledDeposit` or
`SettledRedeem` callback atomically, and the gateway retries it later: only revert to intentionally
block; best-effort observers try/catch their own downstream calls. A heavy observer, hook or route is funded
per fulfilment through `Fulfillment.extraGasLimit` and, on the request side, the router's per-pool extra gas.

Supported:

| Behavior | Mechanism |
|---|---|
| Fee crystallization with high-water marks | per vault, on the spoke: execution price from fulfill callbacks, periods anchored on the delivery block; a pool-wide mark needs a hub-side record (see Hub-side execution); fee *minting* is a hub/manager concern |
| Compliance registers (trade date vs settlement date) | the hub `Fulfill` event carries the trade (pricing) time and the spoke callback is the settlement date; the one observer that *should* revert to block |
| SLA / latency monitors | request-open time recorded via composed `onRequest`; latency = settlement block time − open time |
| Collateral notifiers for lending markets | controllers via composition; pushes try/caught (non-blocking by convention) |
| Tranche waterfalls, insurance triggers | flow-driven repricing in `onSettle`; pure NAV markdowns read from registry prices via keeper poke |
| Tax-lot ledgers | per-controller lots opened/closed via composed request policy + settlement amounts |
| Auto-compounding / auto-bridging of proceeds | observer claims and re-requests for users via per-user `setOperator` opt-in; claims are `nonReentrant`, so this fails when the callback runs inside the vault's own flush (a local instant-settlement manager) and works for hub-driven callbacks |
| Liquidity-buffer thermostats | observer + balance-sheet manager hybrid, reacting to each settled fill |

Not supported / remaining gaps:

- **Per-controller callback fan-out**: buckets are opaque to a standalone observer; knowing
  the contributors requires composing the request policy. Accepted trade-off.
- **Snapshot-consistent supply**: dividend checkpoints at hub valuation time would need a
  checkpointed share token or a hub-supplied snapshot supply.
- **Valuation timestamp ≠ delivery timestamp**: they differ for any remote spoke and for a retried
  message, so `onSettle` sees delivery time. The pricing time is in the hub `Fulfill` event; an observer that
  needs it on the spoke would need a timestamp added to the callback.

## Vault oracles (`IVaultOracle`)

A single direction-, size-, and caller-blind mid-price view, `prices`, returning the pair together
with a validity verdict: instant flows require the verdict, while the neutral `convertTo*` views
read the prices and ignore it. Oracles may expose any
additional mutating surface of their own (keeper updates, attestation posting, calendars).

Supported:

| Pricing model | Mechanism |
|---|---|
| Accrual extrapolation between hub pushes | anchor + rate on the oracle's own admin surface; capped extrapolation window |
| Linear reward-drip vesting | funded rewards vested linearly over a fixed period so the price rises smoothly (USHPi 35d, sUSDe 8h); anchor + rate on the oracle's admin surface, a zero-supply guard so nothing vests into an empty vault, and lazy checkpointing on user actions plus a scheduled keeper checkpoint |
| Strategy / loan-book NAV | hub-side valuation, not vault code: a pool manager runs the strategy, a valuation or NAV manager publishes the mark, and `SpokeOracle` reads it; the vault stays thin (sUSDai) |
| Chainlink / Pyth-fed NAV | push feeds read directly; pull oracles via keeper- or frontend-bundled updates |
| Secondary-market TWAPs | Uniswap `observe()` over a configured window; best as one leg of a medianizer |
| Multi-source medianizers with deviation breakers | composes over other `IVaultOracle`s; latched trip state via keeper poke |
| Market-hours gating | an out-of-hours `valid = false` blocks instant flows while `convertTo*` and `totalAssets` keep serving the last price (the previews revert on an invalid price) |
| Staleness bounding | `SpokeOracle` takes an immutable `maxAge` and reports the pair invalid once either hub price is older. Registry validity only means a price was notified at least once, so this is the only age bound in the stack; `maxAge == 0` disables it. `maxSkew` bounds the gap between the asset and share notification times, and a paused pool reads invalid |
| Emergency stop | `SpokeOracle.pause(poolId)` by the pool's spoke managers, at once, on the spoke's chain; unpausing is only through `fromHub` under the pool policy (an out-of-policy, delayed call) |
| FX composition for cross-currency assets | hub NAV for the share leg × live FX feed for the asset leg |
| Floor / cap bands | clamp or reject any inner oracle's price against a hub-anchored band |
| Tranche waterfall pricing | per-scId senior accretion / junior residual computed hub-side from one pool NAV and delivered as per-share-class prices, which `SpokeOracle` only reads |
| Admin-signed NAV attestations | m-of-n EIP-712 attestations posted via the oracle's own write path |

Not supported, by design:

- **Directional or size-dependent pricing**: a spread in the oracle would poison the neutral
  `convertTo*` views integrators read. Spreads and haircuts belong in `IInstantPolicy`'s
  signed fees (penalties skimmed, credits paid from a funded fee source).
- **Calldata-embedded updates** (RedStone model): the vault call's calldata never reaches the
  oracle; use the posted-update (Pyth) model instead.

## Share token restrictions (`IRoleHook`)

The share token's hook decides who may hold, leave or be paid; the vault decides what each of its actions
asks of whom. `VaultActionLib` turns every vault action (requests, claims, refunds, instant trades and request
transfers) into role checks, each naming the account that answers to the role (`Entry`, `Exit`, `Payout`,
`Refund`) and the one the value comes from, and asks the share token's current hook, once for the whole action: `onRoles` enforces and must
revert to block, `checkRoles` is its view twin behind the `max*` views. The mapping is in `src/vaults/ARCHITECTURE.md`
("Share token restrictions"). There is no vault slot for it, so the gate cannot be left off a vault and follows the
token when the pool swaps its hook. A token with no hook is unrestricted; a hook without the `IRoleHook` surface
makes every vault action revert.

Supported:

| Requirement | Mechanism |
|---|---|
| Memberlist / KYC gating on requests and claims | the full-restrictions and freely-transferable flavors of the shipped `ShareTokenHook` gate `entry` on the party taking shares or a position |
| Freeze that reaches operations with no transfer leg | every role check refuses a frozen source or destination: a request's payer, its controller, a claim's controller and receiver, both ends of a request transfer |
| Redemption-only restriction | the redemption-restrictions flavor gates membership on `exit` and lets deposits through |
| Gating who may receive a traded pending position | a request transfer asks the role of its position of the new holder, from the old one |
| Per-call state (lockups keyed by account) | `onRoles` is mutating; a stateful hook must restrict its callers to the contracts it serves for the token, since the vault is the caller |

Not supported, by design:

- **Seeing the caller**: `onRoles` is invoked by the vault, so `msg.sender` is the vault, not the
  originating account. The two parties of a check are the identity surface; a hook cannot distinguish an
  operator from the controller acting directly.
- **Seeing the operation**: the hook sees a role and two accounts, not which vault action asked. A rule that
  depends on the operation (instant but not async exits, request counters, per-window caps) belongs in the
  vault's plugins, which see it: the instant policy's allowlists, the request policy's gating.
- **Who may credit a position to someone else**: a vault question, not a hook one. A vault with an instant
  lane asks its instant policy (`canCredit`) whenever the caller does not act for the controller, since a
  position pushed onto a controller holds its instant lane closed until it is settled and claimed;
  `ReserveInstantPolicy` answers from a per-vault sponsor list the pool sets from the hub, nobody by default. The
  controller's own requests and its operators' need no sponsor. Without an instant lane nothing routes on a
  pending position, so the vault asks nobody and any caller may credit any controller, as in v1.
- **Transforming an operation**: the hook returns no amounts. It permits or reverts.
- **Observing share movements with an enforced leg**: issuance (instant included, where the receiver is gated)
  and deposit claims reach the token's transfer hook too. The vault asks role checks for them as well, so the hook
  sees the payer of an instant deposit and the controller of a claim, which the share leg does not name.

## Redemption models and the request manager

Beyond the plugins, one more component decides *how a redemption settles*: the pool's
registered **request manager**: the contract the vault flushes async requests to
(`IVaultRequestManager`) and receives callbacks from (`IVaultDepositCallbacks` /
`IVaultRedeemCallbacks`). It is swappable, not vault
logic, and three models cover the validated designs:

- **Instant**: an atomic redeem at the oracle price through the instant lane (`IInstantPolicy`),
  no request manager involved. Fine when liquidity is always on hand; sUSDe's zero-cooldown
  mode is exactly this.
- **Floating async (default)**: `requestRedeem` flushes through the default
  `VaultRequestRouter` to the Hub, where the manager fills the order, in part as
  liquidity allows, and sets the fulfillment price (the engine has no queue or window; a servicing window is
  the manager's practice). The shares stay in the price denominator
  until fulfilled, so a pending redemption floats with NAV. This is sUSDai (a 30-day
  manager-serviced window); a hand-rolled redemption queue is deleted, not ported.
- **Fixed-price cooldown**: an **instant-settlement request manager** registered in place of
  the default router fulfils the redemption itself instead of forwarding it. On the flushed
  redeem it reads the vault's oracle to fix the payout at the request price and sends
  `revokeShares` (burning the shares and reserving the payout, which removes the position
  from the yield base), then holds `fulfillRedeemRequest` until the cooldown timer elapses,
  when a keeper or a permissionless call releases the claim. Both are the vault's existing
  callback handlers, called directly, so this reuses the whole settlement path (pro-rata fold, claimable
  ledger, ERC-7540 claim surface) with no vault-specific redemption logic; the cooldown is just
  the gap between the two callbacks. This is USHPi and sUSDe, and the fixed amount is reserved
  in the escrow, so a separate silo contract (Ethena's) is not needed.

Local settlement only works where the payout is reservable from idle backing: a strategy vault
whose backing is deployed keeps the floating path. The redemption is priced once, at request
(the Hub never reprices it), so checkpointing a reward-drip oracle before pricing keeps the Hub
NAV and the oracle price equal at that instant, and the removal is a clean pro-rata. Because an
instant-settled redemption routes no Hub approval, it cannot be partially fulfilled or
cancelled into an over-burn. The one operational difference from the floating path: the
fulfillment is triggered locally rather than pushed by the Hub, so after the cooldown the
instant-settlement request manager, which alone may call `fulfillRedeemRequest` on the vault, exposes a
permissionless release (a keeper, or the claiming user's own multicall). The shares are already burned and the
payout reserved, so a late trigger only delays when the claim opens.

## Worked examples: three staking tokens

Each of these is a composition of the spoke-side plugins above (a deposit-access policy, a
yield source, and a redemption model), not a bespoke contract. All three keep compliance in the
share-token transfer hook.

- **USHPi (Centrifuge)**: deposits are Merkle-gated and capped through a front-door router
  composed with an instant policy; yield is a reward drip modelled by a custom `IVaultOracle`;
  redemptions are priced at request and self-serviced after a cooldown via an
  instant-settlement request manager, with the payout reserved in the escrow. Pending
  shares stop earning once redemption is requested.
- **sUSDai (USD.AI)**: open deposits on the instant path; yield is strategy NAV published
  hub-side, so the vault stays thin; redemptions float until a manager services them within a
  liquidity-gated window (the default async path), so pending shares keep earning until filled.
- **sUSDe (Ethena)**: open deposits (instant path plus a restriction hook); reward-drip yield
  like USHPi; redemptions fixed at request and self-serviced after a cooldown. The
  instant-settlement request manager reserves the payout in the escrow, so Ethena's
  separate silo contract collapses into an escrow reservation.

Read the table by column: each token is one choice per row.

| Dimension | USHPi (Centrifuge) | sUSDai (USD.AI) | sUSDe (Ethena) |
|---|---|---|---|
| Deposit access | Merkle-gated, capped (front-door router + instant policy) | open (instant path) | open (instant path + restriction hook) |
| Yield | reward drip (custom `IVaultOracle`) | strategy NAV (hub valuation) | reward drip (custom `IVaultOracle`) |
| Redemption price | fixed at request | floats until serviced | fixed at request |
| Redemption servicing | self-service after cooldown | manager-serviced, liquidity-gated | self-service after cooldown |
| Pending shares earn? | no | yes | no |
| Redemption model | instant-settlement request manager | stock floating async redeem | instant-settlement request manager (silo becomes escrow reservation) |
| Compliance | share-token transfer hook | share-token transfer hook | share-token transfer hook |

## Hub-side execution: the OrderBook engine, wrapper managers, and the pool policy

The six spoke-side plugins shape how requests *form*. Once a bucket is flushed, execution
happens hub-side, across three pieces: a minimal `OrderBook` engine, a wrapper manager that
holds the fee policy, and the pool policy that bounds every number the manager supplies:
`OrderBook`, `FeeRequestManager` and the OrderBook branch of `StdHubPolicy`. Fees and pricing are
manager-supplied call parameters bounded by the pool policy, not an amount-transforming hook, so the
engine has no load-bearing callback.

The three pieces:

- **`OrderBook`, a minimal per-order engine.** Each flushed request is an independent order
  keyed by its vault-namespaced `RequestId` (no epoch, queue or pro-rata), and auto-approves
  into `outstanding` on receipt. The manager fulfills (issue on deposit, revoke on redeem),
  then cancels any remainder. Every economic number is an explicit call parameter: the fill
  amount, a fee-adjusted `netAmount`, and the prices. The engine holds no fee or pricing policy
  of its own. `net < fill` is a fee the pool retains (fewer shares on deposit, fewer assets on
  redeem); `net > fill` a rebate the pool pre-funds. A fulfillment sends one atomic
  `SettledDeposit`/`SettledRedeem` callback and a cancellation one `CancelledDeposit`/
  `CancelledRedeem`, so a fill cannot land partially on the spoke.
- **The pool policy bounds the numbers.** Because `netAmount` and price are call parameters
  and not a hook return, `StdHubPolicy` sees them in the `managerCall` calldata and bounds
  them before the call runs: both prices against the pool's committed share/asset prices
  (`maxFulfillPriceDeviation`), and the fill-vs-net delta against `maxFeeBps` for a fee and
  `maxRebateBps` for a fulfillment rebate. Cancels carry no price and are bounded on the fee only:
  a cancel never rebates, which the engine enforces and the policy classifies out of policy. This is the pool policy's existing authorize model with an OrderBook
  branch added; a compromised or buggy manager cannot exceed the bound instantly: a call outside it
  classifies as time-locked and sentinel-vetoable, and through `FeeRequestManager` it is a hard stop
  (`NotInPolicy`). A pool may set a bound to its maximum, or run with no policy, which leaves it unbounded.
- **A wrapper manager holds the fee policy.** `FeeRequestManager` is registered as a pool
  manager alongside the operator. It reads the committed prices from the Hub, computes
  `net = fill - fee` from a per-asset bps schedule, and forwards the action to the
  OrderBook through `Hub.managerCall`. The Hub sees the wrapper as the caller, so a wrapper must also ask the
  pool policy about its original caller, as `FeeRequestManager` does (`policy.authorizationDelay`), or it
  bypasses a confined caller. Products needing bespoke execution (netting, auction
  pricing, auto-servicing) are other wrapper managers; they run as ordinary callers outside the
  engine's invariant boundary, so a wrapper bug cannot corrupt engine accounting and is
  recovered by re-registering the manager.

The one thing a wrapper cannot see is the *incoming request*: issue, revoke and cancel are all
manager-initiated, but arrival is spoke-driven. `OrderBook` keeps a single narrow hook there,
an optional per-pool **`IRequestObserver`** fired on arrival after the order is recorded. It is
deliberately weak: no return value, no amount transformation. It is the pool's choice, so it is
called plainly: a revert fails the request message (retryable), and a heavy observer is funded
through the router's per-pool request extra gas. Hard request gating stays spoke-side in the
vault's request policy, where declining is clean and free.

Mapping the behaviors from the tables above onto this design:

| Behavior | Mechanism |
|---|---|
| Entry/exit fees at execution | one per-asset bps in `FeeRequestManager`, applied to deposits and redeems alike (it never rebates and cancels at `net == amount`); different entry and exit fees need a custom wrapper; the skim accretes to NAV and surfaces as a worse execution price; the pool policy caps it via `maxFeeBps` |
| Early-exit penalties (lockups, cliffs, anti-churn) | the spoke request policy records a penalty tag against the bucket key (the vault maps it to the localId through `bucketOf`); the wrapper (fed by a keeper when the spoke is remote) charges only flagged fills |
| Tiered fee classes | tier recorded against the bucket key spoke-side; per-tier schedule in wrapper storage |
| Notice-period early-service fees | the request policy keys each window by its maturity; the wrapper charges pre-maturity fills |
| Swing pricing at execution, pool-global | a wrapper conditions the fee on net flow it accumulates; the hub sees every issue and revoke across all spokes, so the condition is global |
| Fee holidays, seeding rebates, equalization credits | a custom wrapper passes `net > fill` (`FeeRequestManager` never rebates); the pool pre-funds the escrow; the pool policy bounds the rebate via `maxRebateBps` |
| Cancellation penalties | a custom wrapper supplies `net` on cancel (a fee keeps the difference); a rebate on cancel is impossible (`NetExceedsGross`) |
| Per-order compliance freeze at execution | the wrapper (or an emergency direct `managerCall`) declines to service that order; removal is a `Cancel`, which refunds the investor |
| Hub-global caps (pool AUM, subscription caps) | an `IRequestObserver` accumulates arrivals; the wrapper or a keeper reads the running total and refuses fills past the cap |
| Auto-servicing, stale-request breaker, netting | an `IRequestObserver` records arrivals (timestamps, flow); a keeper drives the wrapper to service, skip, or cancel accordingly |

Most behaviors that look like they need a new extension point are expressible, because the
wrapper is a caller (it can read prices, call oracles, initiate follow-on actions) and the
pool policy bounds it. What genuinely still needs a new extension point:

| Candidate | Missing primitive |
|---|---|
| Pool-wide high-water-mark fee crystallization, trade-date registers | a post-fulfillment hub observer: the `IRequestObserver` fires at arrival, not at settlement, so a pool-wide anchor on execution prices needs the fulfilling wrapper to record its own fills (a direct `managerCall` bypasses it); per vault, the spoke-side observer covers it |
| Automatic fee split on the async lane | the fee stays unreserved in the escrow for the balance sheet manager to withdraw, not auto-routed; a recipient split needs a dedicated primitive or a splitter the manager pays into. On the instant lane the recipient is a splitter contract (see Instant policies) |
| Reject-with-refund at request | the observer cannot reject; a hub gate that refunds instead of parking the message in the gateway retry queue would need a request-phase cancel path |

How the fee reconciles back to the spoke:

- **The fee is reported, not stranded.** The spoke escrowed the user's full amount, so the
  callbacks carry both the fill and its outcome: a fulfillment carries the filled amount (which
  retires the pending request) and the output priced from the net amount, and a cancellation
  carries the gross amount (which releases the request-time reservation of a deposit) and the net amount the
  investor may claim. For a cancelled deposit the difference stays in the escrow, unreserved, as pool assets;
  for a cancelled redeem the difference in shares is burnt from the escrow, so it accretes to NAV.
- **Fees can leave the pool.** The unlocked difference is ordinary pool assets, so the pool
  manager withdraws it through normal balance-sheet management. There is no built-in automatic
  split to a named third-party recipient, but extraction is not blocked.
- **No amount transformation at arrival.** The observer cannot change the request (it blocks it only by reverting), so
  the request-time desync (spoke escrows the amount, hub records something smaller) never
  arises: the fee is applied at fulfillment, where both amounts are on the wire. Request-time
  gating belongs spoke-side.
- **Price authority is the pool policy's, not a hook's.** The wrapper reads the committed price
  and the pool policy bounds any manager-supplied price against it. A tighter band is a lower
  `maxFulfillPriceDeviation`, or a wrapper that clamps to a band it reads itself, not a new engine hook.

## Why a wrapper, not a hook

A hook and a wrapper differ only in call-flow position: a hook is a callee inside the engine, a
wrapper a caller above it. Since every fill transition is manager-initiated, a wrapper already
covers all of them, and it can call anything (oracles, netting engines, other pools) as an
ordinary caller. A hook making external calls does so inside the engine's money-path
transaction under the reentrancy rule, where a reverting dependency blocks fills. The
genericity the hook was reaching for (the use cases we cannot enumerate in advance) is better
served on the caller side, where unforeseen logic lives outside the invariant boundary. The
engine keeps one narrow, non-load-bearing hook (the arrival observer) for the single flow a
wrapper cannot reach.

## Worked hub-side examples

The spoke-side examples were compositions of plugins; the hub-side ones compose the OrderBook, a
wrapper manager, the pool policy, and one more building block: the **Onchain Portfolio Manager**
(`OnchainPM`). It is a per-pool Weiroll VM that runs only scripts a strategist has been
pre-authorized for. Governance sets a Merkle root of allowed script hashes per strategist, and
`execute(commands, state, stateBitmap, callbacks, proof)` runs a script only when its hash is
proven against that root. A `stateBitmap` pins governance-fixed state slots (write-protected at
runtime, so the strategist fills only the free parameters), and pre-committed `(hash, caller)`
callbacks allow flash-loan-style re-entrant steps. Scripts are arbitrary onchain workflows:
supply, withdraw, swap, bridge. It is the pool policy philosophy ("bound what runs, let the operator
fill the rest") applied to arbitrary calls rather than manager actions.

A wrapper manager can batch an OrderBook action and an Onchain-PM script into one gateway batch,
which is what makes the following possible. The two designs below are illustrations: `LiquidityDistributor`
and `TrancheWaterfallManager` are not in the repository.

### Exact cross-chain redemption liquidity

The problem: a multi-chain pool must land exactly enough asset liquidity on each spoke to pay that
chain's redemptions. Pre-bridging by forecast either strands liquidity on the wrong chain or
starves a chain and stalls claims.

The composition is a `LiquidityDistributor` wrapper over the OrderBook plus the Onchain PM:

1. The hub manager commits, per (pool, asset), a bridging script into the Onchain PM's script
   root: e.g. "pull N of the backing asset from the balance sheet, swap to the payout asset if
   they differ, bridge via CCTP to the spoke." The recipient and destination chain are pinned in
   write-protected state slots; only the amount is filled at runtime.
2. Redemption backing is on-ramped to the balance sheet on the hub chain (typically Ethereum
   mainnet, where liquidity is deepest and swaps are cheapest).
3. On each redemption, the `LiquidityDistributor` batches, in one gateway batch: (a)
   an `OrderBook` redeem `Fulfill`, which fixes the payout at the fulfillment price, burns the
   shares, and reserves the payout; and (b) an Onchain-PM `execute` that moves exactly that payout,
   swaps if the payout asset differs, and bridges it to the spoke so the reserved claim is
   physically funded.

Because the runtime amount equals the revoked payout (wired through the script's state), each
chain is funded to the exact redemption, never more or less; holding a single reserve asset and
swapping per payout means liquidity is pre-positioned once and serves any asset. This is squarely
caller-side composition: a hook (a callee) could neither initiate the bridge nor hold it in one
batch with the revoke. The wrapper does both, and the Merkle root bounds which bridge/swap can run.

### Tranche waterfall with guaranteed senior-before-junior redemptions

Setup: one pool with two share classes, senior (`scId_S`) and junior (`scId_J`). Senior has
redemption priority and a floored accrual; junior is the residual first-loss tranche. Pricing is
per-share-class and deterministic from one pool NAV: `seniorNAV = min(seniorSupply ×
accruedSeniorPrice, poolNAV)`, `juniorNAV = poolNAV − seniorNAV`, each divided by its supply,
junior floored at zero. That split is oracle/valuation work (the vault-oracle table already lists
tranche waterfall pricing), and more senior tranches generalize to a strict priority ladder.

The hub-side problem is not pricing but ordering and coverage: when both tranches redeem, senior
must be made whole before any junior payout is released, even when the two tranches sit on
different chains. A `TrancheWaterfallManager` wrapper can guarantee this because every order lands
in the OrderBook hub-side regardless of origin chain, giving it the global cross-chain view a
per-chain policy never has. On a servicing pass it:

1. reads outstanding redeem orders for both share classes from the OrderBook, and the redeemable
   liquidity (balance-sheet available on the hub plus what the LiquidityDistributor can source);
2. computes the waterfall: `seniorRequirement = Σ senior orders × seniorPrice`, junior residual =
   `liquidity − seniorRequirement`;
3. fulfills senior orders first (redeem `Fulfill`), and fulfills a junior order only from the
   residual, never fulfilling a junior redeem while senior coverage is below 100%.

Two tiers of guarantee, matching the fee and price bounds elsewhere in this design:

- **Wrapper-enforced:** the committed wrapper code sequences the calls and reverts on any junior
  fulfillment while senior is uncovered. Trust rests on the wrapper's audited code.
- **Policy-enforced (stronger):** a custom hub policy (`StdHubPolicy` has no such branch) refuses a junior-`scId` redeem `Fulfill`
  unless a senior-coverage precondition holds (senior outstanding × price ≤ reserved NAV), reading
  `ShareClassManager` and holdings. Then even a compromised manager cannot jump the queue. This is
  the tranche analog of the price-deviation band.

Loss absorption falls out of the pricing: if NAV drops below the senior claim, junior price floors
at zero, where a junior redeem cannot be fulfilled (a zero converted output is rejected) and can only be
cancelled, refunding its shares through `mint`.
Composed with the LiquidityDistributor, senior payouts bridge to senior holders' chains first.

### More in the same shape

- **Netting / crossing**: within a dealing window, match deposit inflows against redemption
  outflows at one NAV before sourcing external liquidity; only the residual reaches the
  LiquidityDistributor, minimizing bridging and slippage.
- **DeFi-sourced liquidity**: as the LiquidityDistributor, but the committed script unwinds a
  lending, repo, or LP position to raise the payout instead of (or before) bridging; the
  pre-committed callback slot covers flash-loan repayment.
- **Dutch-auction servicing**: for a redemption backlog, price fills on a decaying curve to avoid
  a fire sale; the wrapper computes the price from elapsed time and the pool policy bounds the band.
- **Capital-call scheduler**: draw committed capital in tranches tagged by call number against the
  localId, charging equalization interest to late contributors through `netAmount`.
- **Fund-of-funds mirror**: a feeder pool's wrapper reads its net flow and initiates matching
  requests into a master pool (a wrapper is a caller, so it can initiate); the master's own manager
  services them.
- **First-loss buffer**: route the fee slice (the fill-vs-net delta) into a buffer holding;
  on a loss event, top up senior payouts from the buffer before junior absorbs. Composes with the
  tranche waterfall.

## Follow-ups outside this surface

1. **Valuation timestamps**: add a pricing time to the settlement callbacks if a spoke needs it:
   `onSettle` already sees delivery time, which differs from the hub's pricing time for a remote spoke or a
   retried message.
2. **Snapshot supply for distribution checkpoints**: checkpointed share tokens or a
   hub-supplied supply-at-valuation, if distributing share classes become a product.
