# Security review: pool isolation

Find every path where a call or message **authenticated for one pool** can read, write, or
spend state that **belongs to another pool**.

## Why this class matters here

Centrifuge is multi-tenant. Pools are mutually distrusting tenants sharing a single set of
singleton contracts — one `Spoke`, one `SpokeRegistry`, one `Hub`, one `AsyncRequestManager`,
one set of hooks and managers. The only thing separating tenants is that every piece of state
and every transfer is supposed to be keyed by, or derived from, a `PoolId` that was
authenticated for the caller.

The trust model (see `docs/audits/out-of-scope/`) says a pool manager is **fully trusted
within the context of their own pool** and **untrusted everywhere else**. So:

- A manager wrecking their own pool, their own users, or their own accounting is **out of
  scope**. Do not report it.
- A manager reaching *any* state, funds, or authority belonging to a pool they do not manage
  is **in scope**. This holds even when every individual configuration step the attacker took was
  permitted for their own pool.

That second sentence is the whole review. The interesting bugs are not "an unauthorized
caller got in" — authentication is generally correct. They are "an *authorized* caller was
correctly authenticated for pool A, and the effect landed on pool B."

## Calibration: a real instance of this class

From the v3.1 Sherlock contest, issue H-1, *"Pool managers can steal all other pools' pending
deposits from globalEscrow via malicious requestManager swapping"*:

A pool could set its own pluggable request manager — a permitted, pool-local configuration
choice. `Spoke.request()` correctly checked `msg.sender == requestManager[poolId]`. But the
matching callback resolved `requestManager[poolId]` **again, later**, so a pool could submit
requests under a malicious manager, swap to the shared `AsyncRequestManager`, and have the
callback credit its own escrow from `globalEscrow` — a resource **shared across all pools**.
Every step was authorized for the attacker's pool. The funds belonged to everyone else's.

Note the shape, because it recurs:

1. The attacker only ever configured **their own** pool.
2. Every authentication check **passed** and was correct as written.
3. The boundary broke at the point where an **effect target** was resolved — a shared escrow,
   and a manager identity re-read at a different time than it was authorized.

Do not go looking for this specific bug; it is fixed. Go looking for its *shape*.

## What to examine

Start from **every externally reachable entry point that takes or implies a `PoolId`**: user
calls, manager calls, guardian calls, and every inbound cross-chain message handler. For each,
trace from the authentication check to every state write and every value movement, and ask:

> Is the pool id that authorized this call the same pool id that ends up keyed in storage,
> and the same pool whose assets move?

Then check these specific ways the answer becomes "no":

1. **Shared or global resources.** Any escrow, balance, queue, counter, accounting entry or
   allowance that is *not* partitioned per pool, or is partitioned by something coarser than a
   pool. Ask who else's value sits in the same bucket, and whether a first-claimer can drain it.

2. **Effect target derived from attacker-controlled data.** The authenticated id is used to
   *look something up*, and the looked-up object then supplies the pool context for the actual
   effect. If the lookup passes through anything a pool controls — a token, registrar, factory,
   hook, manager, valuation, adapter, or any address a pool supplied — the result must be
   re-validated against the authenticated id before it is used. Following such a pointer without
   checking where it landed is the single highest-yield thing to look for.

3. **State keyed by a proxy object rather than by pool.** Mappings keyed by a vault, token,
   escrow, manager, or request id instead of by `PoolId` inherit whatever pool that object is
   currently associated with. If the association can change, or can be chosen by a pool, the
   key is not a trust boundary.

4. **Identity drift between two points in time.** Anything authorized at request time and
   re-resolved at callback, claim, settlement, or retry time. Configuration a pool can change
   in between is attacker-controlled. Compare what was checked *then* with what is used *now*.

5. **Namespace collisions.** Salts, ids, addresses, or slots derived from values a pool
   chooses. Can one pool compute into another pool's namespace, reserve an address another
   pool will later need, or claim a slot it does not own?

6. **Reuse across trust domains.** Any handle — an address, an id, an index — that is
   released, retired, unlinked, or deleted, and can then be re-acquired by a different pool
   while still carrying state, permissions, or pointers from its previous owner.

7. **Aggregate buckets with no per-claimant accounting.** Reservations, entitlements, or
   allowances tracked as a single total per (share class, asset, reason) rather than per user
   or per request. Anyone who can produce a claim against the aggregate can consume value
   another pool's users put there.

8. **Cross-chain message handling.** An inbound message carries a pool id chosen by the
   sender. Verify what actually constrains it, and whether a pool that controls its own
   messaging path can emit a message naming a pool it does not own.

## Method

- Work from the code, not from documentation or comments. A comment asserting an invariant is
  a hypothesis to test, not evidence. Where a comment claims a check exists, verify it does.
- For any candidate, build the concrete path end to end: which entry point, which
  authentication passed, which state or transfer belongs to the other pool, and what the
  attacker configures beforehand. If you cannot name the attacker's pool, the victim's pool,
  and the exact storage or transfer that crosses between them, you do not have a finding.
- Prefer reading the whole flow to grepping for a pattern. These bugs live in the seam between
  two functions that are each correct alone.
- Check the out-of-scope list before reporting, and say why your finding is not covered by it.
  An item that acknowledges a mechanism but scopes its consequence to the pool's own liveness
  or its own users does **not** cover a cross-pool loss of funds.

## Output

For each finding, in severity order:

- **Title** — one line.
- **Path** — entry point → authentication that passes → where the pool id is lost or replaced
  → the state write or transfer that lands on another pool. Cite `file:line` at each step.
- **Attacker setup** — what the attacker configures for their own pool, and why each step is
  permitted.
- **Impact** — what the victim pool loses, and what bounds it.
- **Why it is in scope** — against the trust model and the out-of-scope list.
- **Fix** — the smallest check that restores the invariant.

If a path looks suspicious but you cannot complete it, report it separately as
*unconfirmed*, with the specific thing you could not establish. Do not pad the list: a single
confirmed cross-pool path is worth more than ten speculative ones.
