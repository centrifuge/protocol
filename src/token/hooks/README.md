# Transfer Hooks

Transfer hooks provide customizable restriction logic for share tokens in the Centrifuge Protocol. They enable pools to enforce compliance requirements, manage memberlists, freeze accounts, and control which operations require whitelisting. A hook is set per share token and sees two kinds of call:

- **Transfer callbacks (`ITransferHook`).** Every share movement with an enforced ERC-20 leg: holder transfers, issuance (including a vault's instant issuance), deposit claims out of the escrow, revocation, and cross-chain transfers. `ShareToken` calls `onERC20Transfer` and the hook classifies the leg by its endpoints.
- **Role checks (`IRoleHook`).** Value that moves without an enforced share leg, or whose leg the transfer hook sees without all the parties: a caller asks `onRoles(token, checks)`, one call for the whole operation, where each check is a `(role, from, to, assets, shares, effect)`: whether `to` may take it from `from` under that role, the value that moves in both units (the vault's exact figure where it has one, the other at the current price, unlimited while the price is not vouched for: before the first price, paused, stale or skewed), and what it does to a position (`Effect`: shares held plus what is pending and claimable, pending redemptions included). The hook knows roles, accounts, values and effects, not what the caller's operation is, so a limit on a position, an exit or a payout is the hook's own logic, needs no action kinds and no price of its own. A hook that limits a value also answers `maxAllowed(token, checks)`, so a vault's `max*` views report the room instead of a capacity that would revert; the reference hook limits none. A position limit counts a vault action once, on its role check: the issuance or escrow release that follows reaches the transfer callback as `Kind.Mint` or `Kind.Release`, so the callback limits only `Kind.Transfer` to an investor (a holder's transfer, a cross-chain receipt), which no role check covers. The callback runs after the token moved the shares, so a balance it reads already includes them; its view twin `checkTransferRestriction` is asked before. A vault turns each of its actions (requests, claims, instant trades, request transfers) into the role checks it needs (`VaultActionLib` in `src/vaults`) and asks the token's current hook, so a vault cannot run without the restrictions its share class carries.

![Hooks architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/hooks.puml)

### `ShareTokenHook`

`ShareTokenHook` is a contract that provides memberlist management, account freezing capabilities, and cross-chain message handling for transfer restrictions. It encodes member validity and freeze status in the `hookData` structure (bytes16) stored per user in the share token, with the first 8 bytes (uint64) representing the memberlist valid-until timestamp and the least significant bit indicating freeze status. Each flavor is a `Policy` passed to the constructor, a mask of roles from `HookPolicies` (one of its four presets, or a combination), which the `policy()` view reads back (see below), and the base derives both `checkERC20Transfer` for transfer callbacks and `checkRole` for role checks from it; `onRoles` reverts whatever `checkRoles` (which runs `checkRole` over the batch) refuses and otherwise returns its selector, which the vault requires, so a contract without the `IRoleHook` surface fails every vault action closed even if it has a permissive fallback. It accepts any caller since the shipped hooks keep no per-call state.

A hook that does keep state must authenticate its caller against the token: `token` is chosen by the caller, and any pool can link a contract of its own as a vault. `isShareClassVault(token, msg.sender)` is that check: the caller is a linked vault and the share class it is registered to issues `token`.

#### Exemptions

Two kinds of address hold a token for the pool rather than for an investor, and both read the same on transfers and role checks:

- **An escrow** counts as a member and ignores its freeze bit. `freeze` refuses one; `updateMember` accepts one, to no effect. On role checks this means a payout into an escrow passes wherever the equivalent transfer would, which is what a fund of funds needs for a manager claiming an underlying redemption into the top pool's escrow, which holds no membership on the underlying's token. `VaultLiquidityRoute` is not an escrow: it takes the underlying position from the top escrow and is paid by the underlying vault, so under `RedemptionRestrictions`, `FreelyTransferable` and `FullRestrictions` the underlying pool has to make the route a member (`updateMember`). Until it does the route reads no capacity and the top vault falls back to its own cash.
- **A linked vault of the token's own share class** (`isShareClassVault`) cannot be frozen, and a freeze bit set on it before it was linked (its address is predictable) is ignored. The vault holds the shares it revokes between pulling them and the spoke burning them, so freezing it would brick every redemption through it. The exemption is scoped to the token: a vault of another share class, including another pool's, is an ordinary account and can be frozen. On transfers the token is the caller, so the check reads it from `msg.sender`.

### Policy

A flavor is a `HookPolicies.Policy` saying, for each of five roles, whether the party must be a member, as in the table below. `Refund`, taking back what the account itself put in, has no bit: only a freeze refuses it. The hook is deployed with its encoded mask. A frozen party fails every role, so membership only adds what is asked beyond that. A member is a live membership or an escrow. How an endorsed contract counts is not the flavor's choice: the roles that take or hold shares (`entry`, `transfer`) accept one, since an endorsed contract holds shares mid-flow for the protocol, and the roles that leave the pool (`exit`, `burn`, `payout`) do not, since an endorsed public relay would otherwise let anyone exit through it.

| Role | Who it is | Endorsed accepted | FreezeOnly | RedemptionRestrictions | FullRestrictions | FreelyTransferable |
|---|---|---|---|---|---|---|
| `entry` | Who takes shares, or a position that turns into shares: an issuance or delivery target | Yes | No | No | Member | Member |
| `transfer` | Who takes shares from another holder, in a plain or cross-chain transfer | Yes | No | No | Member | No |
| `exit` | Who leaves the pool: gives up shares, or a position, to be redeemed | No | No | Member | Member | Member |
| `burn` | Who burns shares outside a redemption | No | No | No | No | Member |
| `payout` | Who receives the proceeds of a redemption | No | No | No | Member | Member |

Both entry points reduce to one hand-over, `_canHandOver(token, role, data, from, to)`: the source must not be frozen, and the destination answers to the role. A share movement is classified once (`leg`: a mint, a release out of an escrow, a fulfillment, a burn, or a transfer) and maps to its role, a mint or a release to `entry` and a transfer to `transfer`, while a fulfillment and a burn are decided on the source alone; a role check names its role and both parties. So a flavor cannot allow a hand-over as a role check that it refuses as the equivalent transfer, or the reverse. A transfer brings both parties' hook data, and a role check's is read from the token. Which roles each vault action asks, of whom, is the vault's: `src/vaults/libraries/VaultActionLib.sol`.

### `FreezeOnly` preset

`FreezeOnly` is the simplest hook implementation that only enforces account freezing. It allows any non-frozen account to receive and transfer tokens and passes every role check without memberlist requirements. Frozen accounts are blocked from both sending and receiving tokens, providing a basic compliance tool for temporarily restricting account activity.

This hook is suitable for pools that want minimal restrictions with the ability to freeze accounts. It uses only the freeze bit of the `hookData` structure, leaving memberlist functionality unused.

### `RedemptionRestrictions` preset

`RedemptionRestrictions` requires accounts to be members before submitting redemption requests, while allowing unrestricted deposits and transfers. It enforces freeze checks for all operations and validates membership on `exit` only: whoever leaves the pool.

This hook enables pools to maintain KYC/AML compliance for investors exiting positions while keeping deposits and secondary trading frictionless. It's useful for pools that want to verify investor identity before allowing withdrawals but don't want to restrict entry or token transfers.

### `FullRestrictions` preset

`FullRestrictions` requires accounts to be members before they can receive tokens in most scenarios. It is the strictest model on holding: membership is checked for issuance, deliveries out of an escrow, cross-chain transfer executions and holder transfers, and for the `entry`, `exit` and `payout` roles. Only fulfillment operations (where the spoke issues to or burns from the escrow) bypass it.

Redemption proceeds are paid under the `payout` role, which asks the receiver to be a member, whoever it is: a holder whose membership lapsed between the redeem request and the claim can claim once it is renewed, and an endorsed contract cannot receive them. `FreelyTransferable` pays under the same rule.

### `FreelyTransferable` preset

`FreelyTransferable` leaves transfers between holders unrestricted, and gates the points where a position enters or leaves the pool: an account must be a member to take shares or a position into the pool (`entry`), to leave it (`exit`, `burn`), and to receive redemption proceeds (`payout`). Freezes bind on both legs of every flow, with the escrow exempt on either side.

This hook suits pools that screen who may subscribe and who may exit, but not who may hold. Because gating the exit is its purpose, the payout receiver must be a strict member (or an escrow), as under `FullRestrictions`, and endorsement does not substitute. Membership is checked again at claim time and not only when the request was submitted, so a `validUntil` that lapses in between can withhold a claim whose assets are already in the escrow or whose shares are already burned. The `max*` views ask with the holder as both parties, so they read zero for an expired holder.

### Hook data and extending a flavor

A user's hook data (`bytes16`, kept in the share token) is laid out as the memberlist valid-until timestamp in the high 64 bits, the freeze flag at bit 0, and bits 1 to 63 free. The base hook never writes the free bits: `updateMember` replaces only the valid-until bits, and `freeze` and `unfreeze` flip only bit 0, so a hook that stores more per investor (an investor class, say) keeps it across a membership renewal or a freeze. Such a hook sets its bits through its own authorised entrypoint, and can carry them across chains with its own `fromHub` call kinds, since `fromHub` is virtual.

Every external and public method is virtual, so a bespoke flavor can override what it needs. A bespoke flavor extends `ShareTokenHook` with one of the presets and adds its rule after `super`: `_canHandOver` is the one for a rule between the party that gives and the party that takes, and `_decide` for a rule on a kind of share movement. A rule such as Reg D investors only dealing with Reg D investors is then one function over the two ends of a hand-over, since a transfer names the giver and the taker, and every relation a vault draws between two parties (a request made for another controller, a claim or an instant trade paid to another receiver, a request transfer) reaches the hook as a role check's `from` and `to`. `test/hooks/unit/RegDExtension.t.sol` is a worked example.

### Ordering

On the vault's actions, asked as role checks, the flavors form a partial order, which `test/hooks/unit/VaultActionPolicy.t.sol` fuzzes over members, endorsed, frozen, escrow and vault parties: `FreezeOnly` allows everything `RedemptionRestrictions` allows, which allows everything `FullRestrictions` or `FreelyTransferable` allows. The last two set the same `entry`, `exit` and `payout` bits and differ only in `transfer` and `burn`, which the vault's actions do not ask, so they agree on every kind. On transfers, `test/hooks/unit/HookLattice.t.sol` checks the ordering, and that the freeze bit of an escrow or of the token's own vault is inert in every flavor while another pool's vault gets no exemption.
