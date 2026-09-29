Out-of-scope list for the Cantina bug bounty on the live deployed code. Latest version: `v3.3.0`. Published to the public mirror, since the bounty is scoped against it.

The bounty's general scope guidelines apply: https://cantina.xyz/code/6cc9d51a-ac1e-4385-a88a-a3924e40c00e/overview. This file is its full out-of-scope list.

### The list

* `src/deployment/`, `src/spell/` and migration code are out of scope: they run once with Root-level wards during a deployment, a migration or a governance cast and hold none afterwards, so what they may do is a governance concern rather than a property of the running protocol.
* The protocol is deployed only on chains with Cancun EVM support and not on zkSync, and issues arising from a compromised underlying chain are out of scope.
* Once `Root.executeScheduledRely` has run for a target, that target acts without the timelock, which the spell pattern relies on.
* The Auth pattern does not check that at least one ward remains.
* Pool managers, hub and balance sheet managers included, are fully trusted within the context of their pool:
  * A pool with no policy installed has an unrestricted manager, including every pool between registration and the governance step that installs one.
  * The four accounting event-role slots on a holding are validated only for account existence, so a pool may wire opposing slots to one account and post self-cancelling entries.
  * A share class's registrar is chosen by the pool with no allowlist, and core validates only that the returned token address has code. Under a standard policy the choice is timelocked and sentinel-vetoable, and only Root can re-point it afterwards.
  * A vault's pool and share class come from the arguments the pool's vault factory supplies, and the vault's own reported ids are never read or checked.
  * Registering an async vault does not check on-chain that the pool has a request manager.
  * A vault address is registered once and never re-registered, so a mistaken registration is corrected by deploying a new vault.
  * Several vaults may be linked to one asset of a share class, and the share token's ERC-7575 pointer is set and cleared by the pool via registrar call rather than tracking link state, and the clear is not validated against remaining links.
  * Async fulfillment resolves vaults through that pointer, keyed by asset address alone, so a missing or wrong pointer stalls fulfillment, and ERC-6909 (nonzero token id) async vaults are unsupported, the shipped factories rejecting them.
  * Requests are keyed per vault while the hub aggregates them per pool, share class, asset and investor, so a request made through a vault the pointer does not name settles on the vault it does, leaving the originating vault's pending amount stale, and cancelling it blocks that vault for the investor until the pool points back at it and force-cancels a fresh order.
  * A share class's manager can force-transfer and revoke shares from any holder through the registrar's auth transfer, so freezes and memberlists are not consulted on the source, and a pool holding another pool's share token as an asset trusts that token's manager not to revoke it from under its escrow, which would leave the holding pool's booked amount overstated until revalued.
  * Hub-driven share issuance has no recipient allowlist, so the recipient is checked only by the pending authorization's review window and the share token's transfer hook, and may be another pool's escrow, which records no deposit for it.
  * Revocation through the share manager relies on the registrar's force transfer, so a custom share token without one cannot be revoked from.
  * The pool's bridging hook may rewrite the receiver, amount, gas limit and refund address of a cross-chain share transfer, and core adopts all four unchecked.
  * Bridger-role contracts supply the sender that BridgeCircuitBreaker keys its authorizations on.
  * The bridger role is keyed by pool rather than share class, so a bridger for one share class may bridge every share class of that pool.
  * Replacing a BridgeCircuitBreaker gives the replacement an empty rate-limit window while the outgoing window is still live.
  * Escrow wards may deny themselves, reserve beyond the available balance, and move tokens independently of the accounting they drive.
  * QueueManager holds the SnapshotQueue address from construction, so the two must be rotated together.
  * Under an on-chain-accounting policy the NAVManager's accounting calls, including swapping a holding's valuation and repricing it, run without further delay once the manager call that reaches the NAVManager has matured.
  * Arbitrage between the different assets and currencies of one pool is the pool manager's to manage.
  * The hub does not check that every pool, share class, asset or other id a manager passes it exists.
  * Replacing a vault or request manager can lose pending request state.
  * Keeping a share class's transfer hooks compatible across networks is the pool manager's responsibility.
* Registering another pool's share token as an asset takes that pool's manager on as a counterparty for every property of the token, and which foreign tokens are safe to hold is the holding pool's judgement rather than a boundary core enforces:
  * The issuing pool chooses the token's registrar, hook, wards and metadata, and core validates only that the token address has code.
  * The holding pool's escrowed position may be revoked or force-transferred from under it, blocked by a hook that reverts or stops being a contract, or diluted by issuance it has no part in or by a registrar whose burn does not burn.
  * The claimant the position is paid out to may be frozen, while pool escrows themselves are exempt from freezing on both legs.
* Retiring, relinking or replacing a share token updates the registry but leaves the deployed contracts as they were, so a token address is expected to be treated as compromised once it has left the registry it was issued under:
  * The token's wards, stored hook data, balances and ERC-7575 pointers all survive, and a retired address may be claimed by another pool through a custom registrar.
  * A token relinked between pools carries the previous pool's wards, which keep whatever its bare `auth` functions allow, including writing raw hook data for any address and so blocking its mints.
  * Vaults of a replaced token stay linked until the pool unlinks them and check the old token's balance and restrictions while the spoke moves the current one, so a spender or operator on an old vault can move an investor's current shares, frozen ones included, and the pool is expected to settle and unlink old vaults at replacement.
* The role slots a pool fills are not checked against the protocol's own addresses, so naming a core contract in one can defeat the authentication that reads it:
  * `Spoke.request` and `Hub.requestCallback` check the raw `msg.sender` so that they cannot be batched, and a request manager set to the gateway passes that check for any batched caller.
* The OnchainPM and its weiroll script guards are defence in depth for a pool against its own strategist rather than a trust boundary, and several of the obligations they rest on are conventions the code does not enforce:
  * An exploit that needs the manager to approve an insecure or misconfigured script is out of scope, for example unpinned state slots that should be pinned, duplicate SlippageGuard assets, permissive guard bounds, untrusted or hook-bearing call targets or an out-of-order executeCallback.
  * Scripts are assumed to be generated and verified with the deterministic off-chain SDK, so unsafe raw weiroll flags such as a full state overwrite are not blocked on-chain, and issues reachable only through hand-authored command bytes, or bugs in the SDK or management app, are out of scope.
  * Strategists sharing a pool's OnchainPM are mutually trusted: they share circuit-breaker windows, and leftover native value is not isolated per strategist, since a VALUECALL draws on the whole balance while execute() refunds only the caller's unspent value.
  * CircuitBreakerGuard keys its rolling window by caller and key but not by the window length, so a script passing a shorter window resets the accumulator early and the cumulative limit does not bind.
  * OnchainPM hashes the bitmap-pinned state slots when it verifies a script's merkle proof and does not re-check them after execution, so a command may overwrite a pinned slot before the command that consumes it reads it.
  * ScriptHelpers.addBps applies no upper bound to its bps argument, unlike subBps, so an upper bound computed through it can be made arbitrarily permissive.
  * Which arguments a script pins in its state bitmap, FlashLoanHelper's lending pool and SlippageGuard's share class and slippage bound among them, is stated in comments and enforced only by the manager's review of the script it approves.
  * SlippageGuard measures the net value change across the assets a script touches, so concurrent balance-sheet activity in the same pool can distort it, and its rounding can report up to 1 wei of phantom loss per asset, so a maxSlippageBps of zero disables swaps.
  * AccountingToken omits ERC-6909 operator support, and a maximum allowance is a decrementing budget rather than an infinite approval.
* Pool managers designated on the Gateway or MultiAdapter control their pool's inbound message path and can bypass adapter consensus:
  * A Gateway manager can call `Gateway.handle` directly with any batch for that pool.
  * A MultiAdapter manager can submit repeated votes for one adapter until its counter reaches threshold.
* A pool's installed policy is a boundary against the pool's own manager, but one built from delay, public scheduling and sentinel veto rather than prohibition. Replacing the policy is itself a manager action, carrying the longer escalation delay. The accepted limits of that boundary:
  * Installing a policy can reset, tighten or broaden the limits in force: each instance keeps its own state (such as the share-price baseline), so a new instance starts with none and a reused one picks up where it left off, and its configuration is independent of the outgoing policy's.
  * A newly installed policy instance has no share-price baseline, so its first executed share-price update per share class is in policy whatever its size, and because holding revaluation is permissionless anyone may trigger that first update to anchor the baseline at a block of their choosing and narrow the deviation the next move may take.
  * A matured out-of-policy authorization is not consumed when the same call later runs in policy, leaving it banked until it expires.
  * Any SetPaused to the configured bridging hook is instant in both directions, so unpausing is as immediate as pausing.
  * The allowlist confines a caller by selector and not by target, so a keeper allowlisted for managerCall can reach any unpinned target after the standard delay, and a keeper allowlisted for unauthorizeSpokeCall can revoke any outstanding authorization of that pool on any chain.
  * Spoke-side authorizations carry no expiry, and the revoke is itself a policy-classified manager call, so a policy that blocks it for every manager leaves an outstanding authorization standing until the pool bumps the spoke policy nonce or Root clears the pool's policy.
  * Under an on-chain-accounting policy repointing a holding's account ids is not reserved for the NAVManager, so a manager can still do it behind the standard delay and sentinel veto, which breaks the NAVManager's accounting for that holding.
* The sentinel veto is instant by design, and sentinels are mutually trusted:
  * Any unrestricted manager reaches the same instant path, so a manager can veto the authorization that would remove them, and can revoke an outstanding spoke authorization.
  * A pool reduced to one sentinel can be deadlocked by that sentinel, two colluding sentinels are mutually unremovable, and recovery is a Root ward clearing the pool's policy or the supervisor's manager role.
  * Authorization spam is bounded only by the assumption that the delay is long enough for sentinels to cancel all of them.
  * A pending out-of-policy manager call whose target word is not a left-aligned address can be neither vetoed by a sentinel nor executed, and lingers until the manager cancels it.
* Cross-chain messages may execute late, out of order or racing each other, and issues arising from that are out of scope.
* Irregular (config-carrying) messages have no ordering or freshness guarantees, and failed deliveries stay permissionlessly retryable until cleared:
  * A delayed or retried UpdateWard grant delivered after its revocation restores the ward.
  * A SetPolicy that failed before pool activation can later be retried, reinstalling an older policy over a newer one.
  * The receiver of a cross-chain share transfer is an opaque 32-byte word that the source burns against without validating it for the destination chain, so a receiver the destination cannot decode leaves the shares burned at the source with the destination mint failed.
* Cross-chain gas accounting is best effort and works from benchmarks rather than guarantees, and a message that fails for gas is recorded and stays permissionlessly retryable with more gas, so the consequence is delay and message volume rather than loss:
  * The per-message processing limit, the failure reserve withheld from the inner call and the caller-supplied extra limit are fixed values that do not model what the EVM withholds from a subcall, so an executor supplying gas near the quoted amount may drive a message into the failure branch.
  * A legitimate message near the top of its budget may fail on an honest relayer.
  * GasService estimates may be too high or too low.
  * Subsidised message funds can be consumed by spam.
* Adapter sets, sessions and vote accounting:
  * Adapters are assumed never to revert, so one faulty adapter blocks outbound dispatch for the whole set.
  * Every past adapter session stays a valid inbound authenticator, and revoking a compromised adapter requires an explicit blockSession.
  * `threshold == quorum` is the supported configuration, and vote-debt effects below it are out of scope.
  * The SetPoolAdapters freshness guard binds the hub message path only, and direct callers derive their own next session id.
  * A failed-message credit records no session, survives blockSession, and stays permissionlessly retryable, so adapter rotations are expected to clear outstanding credits atomically with blocking the old session.
  * StandbyAdapter.forward is callable directly and funds the underlying send with the full value attached, so a direct caller who overpays against an underlying that keeps the excess loses it, while the MultiAdapter path always funds the exact quote.
  * Narrowing a Chainlink lane's accepted finality rejects messages already sent under the wider setting until it is wired back and they are retried.
* The protocol and ops safes can act without the Root timelock in these cases:
  * The ops safe installs each remote network's first global adapter set, which authenticates RegisterAsset and every pool's first SetPoolAdapters on that lane, and does each adapter's first wiring.
  * The ops safe can block any global adapter session, mainnet's included, and only a Root spell installs the replacement.
  * The protocol safe holds a ward on the LayerZero and Hyperlane adapters, so it can re-wire them directly.
* Guardians assume a Safe admin, and when the admin is not a Safe a pause can only come from the admin itself rather than from individual owners.
* Cross-version messaging and migration behaviour during the v3.3 rollout:
  * Message types carry no reserved gap slots, and undrained v3.1 messages stored or in flight at cutover may be dropped.
  * The deployed v3.1 spoke stack runs in parallel through migration, with per-pool cutover and deprecated compatibility overloads.
  * Transfer hooks recognise only escrows deployed by the current EscrowFactory, so an escrow deployed by an earlier release is treated as an ordinary account by a v3.3 hook.
  * Holdings deficits are not carried across the Holdings redeployment, so a network in deficit at cutover reads zero and resumes publishing until a new deficit is recorded.
  * Initiating a cross-chain share transfer performs no per-network net-supply check on the hub, so issuance can be moved from a network whose reported issuance does not cover it.
* Automated price propagation can stall or hold the last published price:
  * Arbitrage on cross-chain price updates is out of scope.
  * SimplePriceManager's price can be moved by deposits that raise assets when on/off-ramp or sync deposits are enabled, and the pool manager is expected to bound that, for example with the maximum reserve.
  * SimplePriceManager prices are off when an approval and its matching issue or revoke are sent separately, since assets and shares are then imbalanced, so the manager is expected to batch them.
  * An out-of-policy price update reverts inside inbound accounting-message handling and stalls that pool, share class and network nonce stream until an operator authorizes it and retries.
  * While any holding of a pool network is in deficit that network's NAV slice is held with no staleness bound, and a pool spanning several networks keeps publishing prices on syncs from the others, blending the frozen slice into the aggregate.
  * A holding valued by an oracle valuation cannot increase or be revalued while its price is unset, decreases skip the valuation, and no staleness bound exists on the stored price.
  * Remote oracle prices are accepted when their source timestamp exceeds the hub receipt time of the stored price, so reordered delivery combined with cross-chain clock skew can restore an older price, and a local setPrice invalidates remote updates authored before it.
  * The same comparison rejects an update authored before the previous one was received, so a feeder's update interval is expected to far exceed the messaging latency, an interval on the order of a day leaving the skew immaterial.
  * Spoke price updates reject a timestamp ahead of the spoke's clock, so an honest price that arrives faster than the skew between the two chains' clocks fails and waits for a permissionless retry.
  * Economically linked asset and liability legs are repriced per AssetId and each leg's update publishes holding value, NAV and share price before the matching leg lands, so legs sent in separate transactions or a partially failed batch expose an intermediate price that pool managers are expected to avoid by batching both updates with sufficient gas.
  * The snapshot hook runs inside inbound accounting-message handling, and since NAVManager rejects a pool with no NAV hook while the policy makes setSnapshotHook immediate and the call arming the NAV hook delayed, a pool that installs the snapshot hook first has a window in which its accounting messages and inbound bridged transfers fail and stall the nonce stream.
  * SimplePriceManager serves only the share class with index one, so a pool with further share classes cannot price them through it.
  * Hub share accounting nets cumulative issuances and revocations so the hub no longer reverts when a revocation is processed ahead of the issuance that minted the shares, but the price manager still reads per-network issuance and stalls its pool's reporting channel in that state, since the price-manager side of that change is not in this release.
  * SimplePriceManager sums issuance and transfer counters in 128 bits and has no reset, so one maximum-size share transfer from a compromised message source, which the hub accepts even with the same network as source and destination, stalls that pool's accounting messages from the affected network until the price manager is replaced.
  * A zero count of networks in negative issuance is not a correctness signal: a network that mints beyond what it has reported and then bridges those shares away leaves total issuance understated while the count stays zero, and the hub has no view of a spoke's full supply to detect it.
  * A holding's value and its accounts' debit and credit totals stay 128-bit, so a maximum-size report from a compromised message source can saturate them and stall that network's accounting messages until the pool revalues the holding or re-points it at another valuation or account.
* Synchronous deposit vaults keep their pre-v3.3 ERC-4626 surface until the vaults v2 redesign:
  * SyncDepositVault's ERC-4626 conversion views price through the async redeem manager's registry share price while deposit and mint execute at the sync manager's valuation price, so a quote and the executed price can differ when a valuation is configured.
  * SyncDepositVault.maxDeposit and maxMint revert with InvalidPrice rather than returning zero while the pool-per-asset or pool-per-share price is still unset.
  * Synchronous deposits evaluate the memberlist and deposit limit against the paying caller rather than the receiver, so maxDeposit for a receiver can be positive for a deposit that reverts on the payer.
  * Transfer-hook freezes bind share senders and receivers, not funders: a frozen account may still fund synchronous deposits through an endorsed router for an eligible receiver.
* Assets, share classes and pool currencies may have as few as 0 decimals, and the economic weight of one rounding unit grows as decimals shrink.
* Share tokens are assumed to stay well below the 128-bit supply cap, since an issuance that would cross it fails on the spoke after the hub has advanced the epoch and the fulfilments that follow draw on other escrowed shares of the same class.
* The hub keeps an asset's decimals from registration while spoke conversions read `decimals()` live, so a token whose decimals change afterwards is mispriced, and pricing against one is the pool's error.
* Asset registration is permissionless and a re-registration may only replace a stored zero, so a token that reports a wrong nonzero `decimals()` before its issuer initialises it keeps that value.
* BatchRequestManager force-cancel flags are set on an investor's first self-cancel and never reset, so a manager can force-cancel that investor's later requests:
  * On a cross-chain pool the spoke accepts a force-cancel only while the investor has a cancel of their own in flight, so otherwise the hub's order is gone while the funds stay reserved until the investor cancels again and the parked callback is retried.
* The amounts a request callback carries are not bounded by the investor's own request, since AsyncRequestManager credits a reported cancellation without capping it and saturates the pending amount at zero, so an over-report from the pool's own hub request manager draws on the escrow's aggregate reservation and is manager error.
* Native value attached to a VaultRouter multicall is neither consumed nor refunded and is recoverable only through Recoverable.
* VaultRouter keeps no per-caller custody, so a claim-and-bridge multicall that bridges a fixed amount leaves any surplus from a fulfilment landing first in the router, where anyone can take it.
* The share manager is endorsed and carries neither wards nor a recovery function, so it cannot be frozen by a hook and any token sent to it directly needs administrative recovery.
* FullRestrictions blocks the system mint leg of inbound cross-chain share transfers unless the destination handler is endorsed or a member, and the source side burns before it can detect this.
* A user transferring share tokens is expected to send them only to eligible receivers, members of a restricted share class for instance.
* TokenBridge routes the first-leg refund of a two-leg transfer to the configured relayer, and the eventual user refund is an off-chain relayer convention.
* The shared vault managers take the vault as a call argument and do not bind it to msg.sender, so any of their wards could act on any linked vault:
  * The binding is left to the vault factories, whose `newVault` is auth-gated to the spoke handler and relies only its own CREATE2 deployment of fixed vault bytecode, which only ever passes itself.
  * Governance keeps the looser form deliberately, so a spell can act on a vault it is not.
* Contracts on the share paths omit a recovery function where the runtime size limit leaves no room for one, AsyncRequestManager among them, so a token sent directly to one of them needs administrative recovery through the share token's authorised transfer.
* The destination handler, the chain ids and the escrow hook id that the transfer hooks key system flows on are neither endorsed nor exempt from freezing, so a hook manager freezing one stops that token's inbound transfers, bridging to that chain or redemption requests respectively until it is unfrozen.
* Liquidity can be stuck while its holder is frozen or while all vaults of a share class are unlinked, and claims of assets and shares stay open while the protocol is paused.
* Redemption and cancellation claims evaluate the burn-side transfer restriction against the receiver the caller names, with the controller checked only on the leg between the two, so a controller who is no longer a member may still claim to a member receiver.
* An ERC-7540 operator approval delegates the controller's whole position on a pool, share class and asset, so an operator approved on the vault the share token points at reaches requests made through the other linked vaults and may claim their proceeds to any receiver.
* AdapterFailover bounds a steward's proposal by its timelock and the other stewards' veto rather than by validation:
  * A revoked steward's pending proposal stays permissionlessly executable until it expires, execution being open by design since the steward may be unreachable when adapters go dark, so governance is expected to send a CancelFailover with the revocation.
  * The timelock is fixed at construction from the Root delay while the CancelFailover veto carries the pool's own policy delay, so a pool reduced to a single steward whose policy delay exceeds that timelock cannot mature a veto before the steward's proposal becomes executable.
  * initiateFailover validates only the threshold floor, so a steward may arm a set that MultiAdapter.setAdapters rejects, and such a proposal fails on execution and expires unless a steward overwrites or cancels it.
* A pool's OnchainPM is neither endorsed nor recoverable and can be frozen by a hook manager, so routing any share token through it is that pool's own risk and its only exit is an authorized script.
* Hook manager grants are stored per hook instance and are not checked against the token's installed hook, and hook data lives on the share token, so grants seeded on an unused singleton hook and memberships or freezes written under the old hook both take effect when the pool swaps hooks.
* The bridging hook is consulted on the hub after the source spoke has burned the shares, and a rate limit of zero is the default for an origin chain the pool has not configured, so bridging from such an origin leaves the shares burned with the destination mint failed until a manager sets the limit and the message is retried.
