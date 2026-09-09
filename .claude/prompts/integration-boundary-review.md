# Security review: the integration boundary

For contracts that core calls into, or that call into core on someone's behalf:
`fromHub`/`fromSpoke` targets, transfer hooks, valuations, registrars, request managers,
snapshot hooks, routers, and anything holding a pool role.

Find every place this contract **trusts something core handed it without checking**, or
**lends its own authority to a caller who does not have it**.

## Why this class matters here

Core's authorisation stops at its own edge. It proves *that* a call was authorised for a pool;
it does not prove what the call points at, who stands behind it, or that the transaction context
you are running in is still yours. Three specific properties of Centrifuge core create the traps.

**1. Routing is a tuple, but authorisation is one field of it.** Core routes by
`(poolId, scId, assetId)` and authorises by `poolId` alone. `IManagerCall` says it outright: the
call is "pool-scoped: any `scId` is encoded in `payload`". So core hands you an authenticated
`poolId` and an **unvalidated `scId` inside opaque bytes**, and expects you to self-validate.
Registry keys (a vault address, a token address) are global, while the authority writing them is
pool-scoped.

There is a rule that decides whether you must check:

- If you **key state** by the identifier — `state[poolId][scId]` — an unvalidated `scId` only
  pollutes that pool's own namespace. Safe by construction.
- If you **resolve an object** from the identifier — a token, a vault, a manager, an escrow — and
  then act on it, you have left your pool's namespace and must re-validate what came back
  against the tuple you were authorised for.

Nearly every finding in this class is a contract that resolved and forgot to check.

**2. Core sees your contract, not your caller.** Permissions are address-based:
`wards[msg.sender]`, `isManager(poolId, msgSender())`. Once a pool grants your contract a role,
core cannot tell who called *you*, and it does not check that an `owner` / `from` / `controller` /
`receiver` you name has any relationship to your caller. Core also endorses periphery routers
wholesale, so every call such a router makes looks, to core, exactly like the user's own.

**3. The transaction context is ambient and outlives your call.** `BatchedMulticall` caches the
initiating caller in `_sender` for the whole batch, and `msgSender()`/`msgValue()` substitute that
cache — the caller, and a zero value — in place of the real ones. `Gateway` keeps `isBatching`, fuel
and payment mode the same way.

Read the substitution condition before reasoning about it: both are gated on
`msg.sender == address(gateway)`, so a callee that re-enters from anywhere else sees the real
`msg.sender` and the real value. That gate is doing the security work, and it is the thing to check
in any contract that keeps its own equivalent — a cached principal without such a gate is the bug.

What core does *not* do is close the context before handing control to an untrusted address, so the
batch stays open across every hook, adapter, refund and token callback made inside it. Historically a
batching `send()` also reported a zero cost, which let payment checks pass for free; that is fixed —
`Gateway.send` returns nothing today — but it is the shape to watch for in any value core reports
back to you mid-batch.

## Calibration: real instances

- *Under-checked tuple.* `OnOfframpManager.update()` validated `poolId` and `msg.sender == spoke`
  but discarded `scId`, so a message authorised for one share class could be aimed at another
  class's manager and rewire its ramps and relayers. The same shape recurs from 2023 to 2026
  across three auditors — it is the signature Centrifuge integration bug.
- *Borrowed authority.* After a router was endorsed, anyone could call
  `router.requestDeposit(..., controller: attacker, owner: victim)`: the router was an operator of
  the victim, so nothing fired. Rated Critical.
- *Unpinned address.* A permissionless helper transferred a flash loan to whatever manager address
  the caller named and then called back into it, so a malicious "pool" satisfied every callback
  check while holding the funds.
- *Context outliving the call.* An ERC-20 re-entered a withdrawal while `_sender` still held the
  manager, so `isManager()` still returned true and the whole escrow was reachable.

## What to examine

For every externally reachable function, and every call this contract makes into core:

1. **Every identifier received.** Which are compared against something, and which are merely used?
   For each unvalidated one, ask who is authorised to supply it. Apply the key-vs-resolve rule
   above: if the identifier selects an object you then act on, find the check — or the finding.
2. **Every address received as an argument** that this contract then sends value to, calls into,
   or trusts the answer of. What on-chain fact proves it is the canonical instance for that pool —
   a factory `getAddress`, a registry lookup — and is that fact checked *here*, or assumed to have
   been checked by the caller?
3. **Every principal named in calldata** (`owner`, `from`, `to`, `controller`, `receiver`,
   `refund`, `reserver`). Is it derived from the authenticated initiator, or taken on trust? If
   this contract holds a role, does a permissionless entrypoint forward straight into it?
4. **The obligations core states but cannot enforce.** `IManagerCall` requires `msg.sender ==
   envoy`; `fromSpoke` additionally "MUST validate `(centrifugeId, sender)`" because it bypasses
   the pool's policy entirely. These are prose, not types. Verify each one is present.
5. **Every external call, and what is still open behind it.** What privileged or transient context
   is live — cached sender, open batch, un-zeroed accounting — and what could a re-entrant call do
   with it? Check effects are written before the call, not after.
6. **Anything read from core whose meaning changes under batching.** `msgValue()` returns zero for
   the whole window, and `isBatching` is observable and flippable by any caller. Does any accounting,
   refund or limit here depend on a value that differs inside a batch?
7. **Discriminated payloads.** If a `kind`/`selector` is decoded, what happens on an unrecognised
   value — revert, or fall through as a silent no-op?

## Method

- Work from the code. A comment asserting a check exists is a hypothesis; find the line.
- Compare siblings. Where several contracts implement the same core interface, diff their guards
  against each other — the odd one out is usually the finding, and the check the others perform is
  the one core could not enforce.
- For any candidate, name the entry point, the authentication that passes, the identifier or
  address that is not verified, and the state or transfer that results. Without all four you do
  not have a finding.

## Before you report: check it is not already accepted

`docs/audits/out-of-scope/` holds the accepted-design list handed to the bug bounty, and the
protocol has been through more than thirty audits. Most well-formed candidates you find are already
known. Before writing up anything:

- Read the out-of-scope list for the release under review, and say for each candidate which bullet
  does or does not cover it.
- A bullet that acknowledges a *mechanism* but scopes its consequence to the pool's own liveness,
  its own users, or its own configuration does **not** cover a loss that crosses to another pool or
  another user. Say so explicitly and keep the finding.
- Where a comment in the code states an invariant, check the code establishes it. A stated
  precondition that nothing enforces is itself worth reporting, separately from any exploit.

Reporting a known item as new costs the reader more than missing it, so state the scope argument
for every finding rather than leaving it implied.

## Output

Per finding, severity order: **Title**; **Path** (entry point → what authenticated → what went
unchecked → the resulting effect, with `file:line` at each step); **Who can reach it**; **Impact**;
**Fix** (the smallest check that restores the invariant).

Report anything you suspect but cannot complete separately as *unconfirmed*, naming the specific
thing you could not establish. A single confirmed path is worth more than ten speculative ones.
