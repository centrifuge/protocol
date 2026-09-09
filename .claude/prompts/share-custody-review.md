# Security review: share custody and hook coverage

For any contract that holds share tokens, moves them on someone's behalf, or is a step on a path a
share position can travel: vaults, escrows, ramps, bridges, managers, and the transfer hooks
themselves.

Find every path by which **a position moves without the restriction check that was supposed to
govern it**, and every way **this contract's own hook status breaks the flows through it**.

## Why this class matters here

Centrifuge gates share transfers with a per-address hook — membership, freeze bits, Root
endorsement — but the hook sits on **one** of the several paths a position can take, and core does
not exempt your contract from it. Three properties create the traps.

**1. The hook sees almost everything, but not always as the flow you have in mind.** Do not assume a
path is unchecked. Issuance and revocation reach it as `(0, to)` and `(from, 0)`, escrow moves and
`Spoke.withdrawShares` reach it as ordinary transfers because the escrow uses a plain `safeTransfer`,
and both cross-chain legs reach it. The one genuinely hook-free path is the registrar's
`authTransferFrom`, whose `onERC20AuthTransfer` is a no-op — which the out-of-scope list states
plainly: a share class's manager can force-transfer and revoke from any holder through it, "so
freezes and memberlists are not consulted on the source".

So the trap is rarely "the hook was not called". It is that the hook is called with a `(from, to)`
pair that does not distinguish the flow you care about, because core reaches several distinct flows
through the same pair. Every burn is pulled to the spoke first, so a redemption and a bridge-out are
both `(spoke, 0)` and no classifier can tell them apart. A custom hook that gates one of them gates
both, or neither.

**2. Restrictions are keyed to an address on a chain; the position is mobile across both.** A
holder who is frozen or delisted here may still be able to bridge out, redeem to a different
`controller`, or move on another chain. Delaying or blocking one action can hand the holder
another. Where a caller chooses the `receiver` or `controller`, the check may be applied to a party
they nominated rather than to the party actually restricted.

**3. Your contract is just another holder.** Core does not exempt protocol contracts. A contract
holding shares is an ordinary `from`/`to`: it can be frozen, it may need membership, and it may
need Root endorsement. Both directions bite. Unendorsed, a hook ward can freeze it and every flow
through it reverts until unfrozen. Endorsed, restricted shares can be pushed *into* it and may have
no way out if it has no recovery path.

## Calibration: real instances

- *Hook bypassed by the privileged variant.* A redemption path used `authTransferFrom` and skipped
  the restriction check entirely, so frozen and non-member accounts could always redeem.
- *Check applied to the nominee.* A frozen controller redeemed successfully by naming an unfrozen
  `receiver`; a sibling claim path transferred assets with no check at all.
- *Delay hands over another exit.* Putting `Freeze` behind a timelock — and publishing its target
  and maturity in an event — let the holder bridge out or redeem under a clean controller during
  the window.
- *Unendorsed intermediary.* A manager contract was not Root-endorsed, so a hook ward could freeze
  it; every hub-driven revocation for that token then reverted until it was unfrozen.
- *Endorsed intermediary.* An endorsed bridge accepted restricted shares transferred directly to
  it, which then had no way out because it implemented no recovery interface.

## What to examine

1. **Enumerate every path a position can leave by** — ordinary transfer, issue, revoke, escrow
   move, `withdrawShares`, cross-chain send, redeem to a chosen receiver, cancellation refund,
   force-transfer, recovery. For each, does it reach the restriction check? Build the list first;
   the finding is almost always the path nobody enumerated.
2. **For each checked path, which `(from, to)` pair is actually passed?** Where the caller supplies
   `receiver`, `controller` or `owner`, confirm the restricted party is the one being checked, not
   a party they nominated.
3. **Privileged versus ordinary variants of the same move.** Where a `trustedCall`, `auth*` or
   governance path duplicates an ordinary one, diff them: which restrictions and accounting does
   the privileged one skip? Is that deliberate and safe here, or merely unnoticed?
4. **This contract's own hook status.** If it holds shares: is it endorsed, a member, freezable?
   Walk every flow through it assuming it has been frozen — what stops, and is there a way to
   recover? If it is endorsed, can restricted shares be pushed into it, and can they get out?
5. **Whether blocking one action opens another.** For each restriction this contract enforces, ask
   what the holder's next-best exit is, and whether it is checked.
6. **Deployment-path symmetry for endorsement.** Endorsement is granted at deploy time. If there is
   both a fresh-deploy path and a migration path, confirm both grant it — a divergence here means
   the contract works on new chains and reverts on migrated ones.

## Method

- Trace one share from issuance to final exit, naming every contract that touches it and which
  check, if any, each one applies. Hook-free paths are invisible when reading a single function.
- Read the hook implementations themselves to learn what they actually check, rather than assuming
  from their names.
- Treat the out-of-scope list as a map of where the hook deliberately does not apply, then ask what
  a contract built on top would wrongly assume from that.

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

Per finding, severity order: **Title**; **Path** (how the position moves and which check is absent
or misapplied, with `file:line`); **Who can use it** (a restricted holder, a manager, anyone);
**Consequence** — say whether a restriction is evaded, value is stuck, or a flow is bricked;
**Fix**.

Report suspected-but-incomplete paths separately as *unconfirmed*, naming what you could not
establish.
