# Security review: pool isolation

Find every path where a call or message **authenticated for one pool** can read, write, or
spend state that **belongs to another pool**.

## Why this class matters here

Centrifuge is multi-tenant. Pools are mutually distrusting tenants sharing per-network
singletons: `Spoke`, `SpokeRegistry`, `Hub`, the `Envoy`, `VaultRequestRouter` (every pool's
spoke request manager), hub-side `OrderBook` and `FeeRequestManager`, `SpokeOracle`, the request
policies, `ReserveInstantPolicy`, the liquidity routes, and one set of hooks and managers. Several
of these hold manager rights on, or accept configuration from, every pool that uses them. Vaults
are per position with immutable policies; escrows are per pool. The only thing separating tenants
is that every piece of state and every transfer is supposed to be keyed by, or derived from, a
`PoolId` that was authenticated for the caller.

The trust model (see `docs/audits/out-of-scope/`) says a pool manager is **fully trusted
within the context of their own pool** and **untrusted everywhere else**. So:

- A manager wrecking their own pool, their own users, or their own accounting is **out of
  scope**. Do not report it.
- A manager reaching *any* state, funds, or authority belonging to a pool they do not manage
  is **in scope**. This holds even when every individual configuration step the attacker took was
  permitted for their own pool.

That second sentence is the whole review. The interesting bugs are not "an unauthorized
caller got in": authentication is generally correct. They are "an *authorized* caller was
correctly authenticated for pool A, and the effect landed on pool B."

## Calibration: two instances of this class

**History (v3.1 Sherlock, H-1).** *"Pool managers can steal all other pools' pending deposits
from globalEscrow via malicious requestManager swapping."* `Spoke.request()` checked
`msg.sender == requestManager[poolId]`, but the callback re-resolved `requestManager[poolId]`
later, so a pool could request under a malicious manager, swap to the shared manager, and have
the callback credit its own escrow from an escrow shared by every pool. That mechanism is gone:
escrows are per pool and the vault stores no manager.

**Current shape (VDK).** `VaultRequestRouter` is registered as every pool's request manager, so
a vault's `onlyRequestManager` check resolves to the same address whichever pool authorised the
settlement. Before the router compared the callback's `(poolId, scId, assetId)` against the
target vault's registry record, a pool registering its own hub-side request manager could send
a callback for its own pool naming another pool's vault and have it applied.

The shape both share:

1. The attacker only ever configured **their own** pool.
2. Every authentication check **passed** and was correct as written.
3. The boundary broke where an **effect target** was resolved: a shared resource, an identity
   re-read later, or an address taken from somewhere the attacker controls.

Do not go looking for these specific bugs; they are fixed. Go looking for the shape.

## What to examine

Start from **every externally reachable entry point that takes or implies a `PoolId`**: user
calls, manager calls, Envoy `fromHub` targets, guardian calls, and every inbound cross-chain
message handler. For each, trace from the authentication check to every state write and every
value movement, and ask:

> Is the pool id that authorized this call the same pool id that ends up keyed in storage,
> and the same pool whose assets move?

Then check these specific ways the answer becomes "no":

0. **Identity source.** For every singleton keyed by vault, confirm the pool comes from
   `spokeRegistry.vaultDetails`, never from the vault itself. Then ask what the registry does
   *not* prove: any pool can link any contract with code through its own vault factory, so
   "linked" is pool identity, not code. Anything read from a vault-shaped address at execution
   time (`share()`, `asset()`, previews, quotes, what it claims to have paid) is attacker data
   unless it is the caller's own pool's vault.

1. **Shared or transient resources.** Per-pool escrows are not the main risk any more.
   Singletons that hold tokens, ETH or approvals transiently (the liquidity routes, the router)
   are. Look for balance-based sweeps (`balanceOf(this)` rather than the delta of this call) and
   approvals left unconsumed after a call returns.

2. **Effect target derived from attacker-controlled data.** The authenticated id is used to
   *look something up*, and the looked-up object then supplies the pool context or the token for
   the actual effect. If the lookup passes through anything a pool controls (a token, registrar,
   factory, hook, manager, valuation, adapter, linked vault, or any address a pool supplied), the
   result must be re-validated against the authenticated id before it is used. Following such a
   pointer without checking where it landed is the single highest-yield thing to look for.

3. **State keyed by a proxy object rather than by pool.** Mappings keyed by a vault, token,
   escrow, manager, or request id instead of by `PoolId` inherit whatever pool that object is
   associated with. If the association can change, or can be chosen by a pool, the key is not a
   trust boundary. Registry vault entries are permanent; check that every proxy key in use is.

4. **Identity drift between two points in time.** Anything authorized at configuration or
   request time and re-resolved at callback, claim, draw, settlement, or retry time.
   Configuration a pool can change in between is attacker-controlled. Compare what was checked
   *then* with what is used *now*.

4a. **Callback binding.** Every inbound request callback must be bound to the target vault's
   registry tuple, since the vault's own caller check names the same router for every pool. A
   locally settling request manager registered by one pool must not reach another pool's vault.

5. **Namespace collisions.** Salts, ids, addresses, or slots derived from values a pool
   chooses: vault CREATE2 salts, vault-namespaced request ids `(vault << 96) | localId`, policy
   local ids. Can one pool compute into another pool's namespace, reserve an address another pool
   will later need, or claim a slot it does not own?

6. **Reuse across trust domains.** Any handle (an address, an id, an index) that is released,
   retired, unlinked, or deleted, and can then be re-acquired by a different pool while still
   carrying state, permissions, or pointers from its previous owner.

7. **Aggregate buckets with no per-claimant accounting.** Reservations, entitlements, credit
   lines or allowances tracked as one total per (share class, asset, reason) or per venue rather
   than per vault or per request. Anyone who can produce a claim against the aggregate can
   consume value another pool's users put there. Note which aggregates are acknowledged (shared
   route liquidity, per-vault payout reservations) and look for consequences beyond the ones
   acknowledged.

8. **Cross-chain message handling.** An inbound message carries a pool id chosen by the
   sender. Verify what actually constrains it, and whether a pool that controls its own
   messaging path can emit a message naming a pool it does not own.

8a. **Envoy targets.** Every `fromHub(poolId, payload)` must key its state by the Envoy-supplied
   `poolId` and validate any payload address (vault, underlying route, observer) against it
   through the registry. The Envoy is reachable by every pool's managers.

## Method

- Work from the code, not from documentation or comments. A comment asserting an invariant is
  a hypothesis to test, not evidence. Where a comment claims a check exists, verify it does.
- For any candidate, build the concrete path end to end: which entry point, which
  authentication passed, which state or transfer belongs to the other pool, and what the
  attacker configures beforehand. If you cannot name the attacker's pool, the victim's pool,
  and the exact storage or transfer that crosses between them, you do not have a finding.
- Prefer reading the whole flow to grepping for a pattern. These bugs live in the seam between
  two functions that are each correct alone.
- Check `src/vaults/SPECIFICATION.md` (the deployment model and its `n` rows) and the
  out-of-scope list before reporting, and say why your finding is not covered by them. An item
  that acknowledges a mechanism but scopes its consequence to the pool's own liveness or its own
  users does **not** cover a cross-pool loss of funds.

## Output

For each finding, in severity order:

- **Title**: one line.
- **Path**: entry point → authentication that passes → where the pool id is lost or replaced
  → the state write or transfer that lands on another pool. Cite `file:line` at each step.
- **Attacker setup**: what the attacker configures for their own pool, and why each step is
  permitted.
- **Impact**: what the victim pool loses, and what bounds it.
- **Why it is in scope**: against the trust model, the spec and the out-of-scope list.
- **Fix**: the smallest check that restores the invariant.

If a path looks suspicious but you cannot complete it, report it separately as
*unconfirmed*, with the specific thing you could not establish. Do not pad the list: a single
confirmed cross-pool path is worth more than ten speculative ones.
