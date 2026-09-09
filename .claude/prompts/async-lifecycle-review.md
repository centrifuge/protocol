# Security review: the asynchronous lifecycle

For any contract whose code is reached by an inbound cross-chain message, defers work to a queue,
or is called back later: hooks, managers, adapters, request managers, snapshot and price
publishers.

Find every place this contract **assumes something about when, whether, in what order, or how many
times it runs** — and every place its own failure stops more than itself.

## Why this class matters here

Centrifuge core is asynchronous by construction, and it gives fewer guarantees than the code
built on it tends to assume. Four properties do most of the damage.

**1. Delivery is at-most-once, but unordered and indefinitely deferrable.** A message cannot execute
twice: each adapter delegates replay protection to its transport (Axelar's `validateContractCall` is
one-shot per command id, and the others are equivalent), and the protocol keeps no dedup of its own
because it assumes the transport provides it. So do not go looking for double execution.

What is *not* guaranteed is when, or whether, or in what order. A message that reverted is stored
indefinitely and anyone may `retry()` it with no deadline; underpaid messages queue for anyone to
`repay()` later. Nothing establishes that a later message supersedes an earlier one, and config
payloads carry no version or nonce. So a message created under one configuration can first execute
under a completely different one, months later, at a moment its sender does not choose — which is a
different hazard from replay and needs different questions.

**2. A batch is atomic exactly as far as its messages cannot fail.** Managers bundle messages that
are only correct together, and the design intends them to land together — that is a fair assumption
to write code against. But each message runs in its own `try/catch`: one that reverts is caught and
parked while the rest of the bundle proceeds. So the assumption holds only while no message in the
bundle *can* fail, and it silently stops holding the moment one can.

The question is therefore not "can an attacker split this bundle" but **"can any message in it
revert, and what do the others assume about it having landed?"** Gas is one way a message fails, and
mis-benchmarked gas limits are an accepted risk rather than something to hunt; a message that reverts
on its own logic is the more interesting case.

**3. Your revert is not local.** Hooks and managers run *inside* inbound message processing, under
a fixed `GasService` allowance, inside the gateway's `try/catch`. A revert or gas overrun does not
fail your function in isolation — it parks the message in `failedMessages`, and where messages are
ordered by a snapshot nonce, everything behind it stops too. The escape hatch may not exist for the
exact case you blocked: a guard that rejects one legitimate value can wedge a stream with no way to
pass that single item without relaxing the limit for everyone.

**4. Core publishes on every write.** `updateHoldingValue` journals and immediately runs the
snapshot hook; on a same-chain deployment `notifySharePrice` lands synchronously with no message or
delay. Core has no notion of "these writes are one economic change, settle them together". If you
model one change as two writes, the intermediate state is not merely observable — a sync-deposit
vault will transact on it.

## Calibration: real instances

- *A bundle split by a failure.* An approve and its issuance were bundled; the second could revert on
  its own, and the first had already landed, leaving a state the sender never intended to be
  observable.
- *Stale supersession.* A replayed `SetPoolAdapters` rolled a route back to a superseded adapter
  set; a stale oracle retry overwrote a newer price, and redemptions were then blessed at it.
- *Wedged stream.* A legitimate NAV swing tripped a guard, the revert unwound the snapshot nonce,
  and every later accounting message failed `InvalidNonce` — retry never cleared it.
- *Gas as a weapon.* A hook staticalled `poolId()` on a *user* address with no gas cap, so a holder
  whose `poolId()` burned gas inflated `freeze()` from ~46k to ~1.56M and made freeze messages fail
  — the attacker watching for the failure event and moving tokens before the retry.
- *Partial publication.* An asset leg and its offsetting liability leg were repriced in two
  transactions. NAV was unchanged at the end, but between them the published share price moved
  ~10%, and a sync deposit in that window minted at a false price, irreversibly.

## What to examine

1. **Reorder, delay, never.** For each message or deferred action this contract handles: if it lands
   out of order, six months late, or not at all, what does it overwrite and what waits on it? Can the
   receiver prove it is not superseded — a nonce, a monotonic timestamp, a version? If the answer is
   "the sender won't do that", find what enforces it. Do not ask what happens if it arrives twice;
   the transport prevents that.
2. **Configuration drift across the gap.** What did this action assume at creation time that a pool
   can change before execution — a manager, an adapter set, a hook, a price, a role? A revoked
   permission that is still sitting in a retryable failed message is a live grant.
3. **Pairings.** Which correctness properties depend on two messages or two writes landing
   together? What stops a third party executing them separately, or under-gassing one?
4. **Your revert set.** Enumerate every way this hook can revert or exceed its gas allowance,
   including on attacker-chosen input and optional interface members that may not exist. For each:
   what stops in core, not here? Does a nonce stream stall? Is there a bounded path for an operator
   to pass one legitimate item without disabling the check?
5. **Worst-case gas.** Any unbounded loop, any call into a caller-influenced address without a gas
   cap, any return-data-sized cost. Compare against the `GasService` allowance for that message.
6. **Publication points.** Which of this contract's writes cause core to publish a price or NAV
   downstream? Between any two of them, is there a state this contract considers incomplete but
   which a sync vault, an oracle reader, or another pool can transact on?
7. **Zero and unset as legal states.** A price of zero is permitted and a fresh share class is
   `(0, 0)`. If this contract early-returns on zero, or arms a baseline only on a non-equal write,
   does its check go blind exactly when pricing is broken?

## Method

- Read the whole flow from message receipt to final state write, including the failure branch.
  These bugs live in what happens *after* the happy path returns.
- For timing claims, name the two orderings and say which core mechanism forbids the bad one. If
  none does, that is the finding.
- Distinguish a liveness bug (something wedges) from a value bug (something is lost or mispriced),
  and say which — both matter here, and they have different fixes.

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

Per finding, severity order: **Title**; **Scenario** (the precise ordering, timing or gas condition,
with `file:line`); **What breaks** — say whether value is lost or the pipeline stalls, and what
else stops with it; **Who can trigger it, and is it permissionless**; **Fix**.

Report suspected-but-incomplete paths separately as *unconfirmed*, naming what you could not
establish.
