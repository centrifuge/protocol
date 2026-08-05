Document reflecting the out of scope list for the ongoing Cantina bug bounty for our live deployed Code. Latest version: `v3.2.0`

## Out of scope

* Pool managers (which include hub and balance sheet managers) are fully trusted within the context of their pool. For the Onchain PM this covers the strategist policies, Merkle-approved Weiroll scripts and guard configuration they set, so any exploit requiring a manager to approve an insecure or misconfigured script is out of scope (e.g. unpinned state slots that should be pinned, duplicate SlippageGuard assets, permissive guard bounds, untrusted or hook-bearing call targets, out-of-order executeCallback).
* Ability to manipulate prices of the SimplePriceManager if on/offramp manager or sync deposits are enabled is known (by depositing to raise assets) => it is up to the pool manager to manage this, e.g. by using max reserve.
* Prices computed in SimplePriceManager may be off if approve and issue or approve and revoke are called separately, as then assets and shares are imbalanced.
* SimplePriceManager.onUpdate may revert, when the ShareClassManager issuance is negative, due to a transfer of shares before a submitQueuedShares, blocking updating a holding value.
* Hub.createPool can be frontrun leading to griefing
* Any issue related to arbitrage between different assets/currencies in the same pool. Should be managed by pool manager
* Any arbitrage related to cross-chain price updates
* Issues related to cross-chain messages not being executed for a long time, in the wrong order or create race-conditions
* GasService estimate is under/overestimated.
* Subsidized funds can be spammed.
* AsyncRequest._withdraw() using current pricePoolPerAsset which is potentially unlikely pricePoolPerAsset during approval of redemption
* Only deployed on chains with Cancun EVM support. And no zksync.
* After Root.relySchedule executes, the timelock does not apply anymore => intentional, combined with spell pattern it works
* Guardian only works with Safe, if the admin is not a Safe the pause can only be executed by the full Safe and not individual owners
* Liquidity can be stuck if a user is frozen
* Liquidity can be stuck if all vaults are unlinked
* While paused, users can still claim assets/shares
* Auth pattern does not check that there is at least 1 ward
* Manager needs to ensure hooks across domains are compatible
* User needs to ensure they transfer valid share tokens eg member
* Issues with underlying networks being compromised affecting the pools deployed on that network
* Missing existence checks in Hub for pool/sc/asset and other IDs
* Updating vault or request manager can cause loss of pending request state
* Onchain PM strategists sharing a pool's manager instance are mutually trusted: they share circuit breaker windows (keyed per manager), and leftover ETH in the manager is not isolated per strategist since a VALUECALL draws from its full balance while execute() only refunds the caller's unspent msg.value
* Onchain PM scripts are assumed to be generated and verified with the deterministic off-chain SDK; unsafe raw Weiroll flags (e.g. full state overwrite) are intentionally not blocked on-chain, so issues only reachable through hand-authored command bytes the SDK would not emit, and bugs in the SDK or management app, are out of scope
* SlippageGuard measures net value change across touched assets, so it can be distorted by legitimate concurrent balance sheet activity in the same pool (on/offramp, async reservation accounting lowering availableBalanceOf); its rounding can also produce up to 1 wei phantom loss per asset, so maxSlippageBps=0 disables swaps
* AccountingToken (ERC-6909) intentionally omits operator support, and a max uint256 allowance is a decrementing budget rather than infinite approval
* Compromise of underlying chains.
* Any migration or spell related code.
