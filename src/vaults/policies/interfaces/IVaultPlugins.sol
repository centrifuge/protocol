// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @notice Instant (synchronous) capacity and fee policy for a vault.
/// @dev    Nullable on the vault: when unset, sync deposits and redeems are disabled.
///         Capacity is expressed in asset terms; 0 blocks the operation. Deposit capacity is
///         keyed by the receiver of the shares and redeem capacity by the owner of the burnt
///         shares, matching the ERC-4626 maxDeposit(receiver)/maxRedeem(owner) semantics.
///         A pool running both lanes should quote a non-zero round-trip spread: the instant lane
///         trades at the notified price, so without one a price jump is a free trade (SPECIFICATION.md).
interface IInstantPolicy {
    /// @notice Maximum assets `receiver` may instantly deposit right now.
    function maxInstantDeposit(address vault, address receiver) external view returns (uint128 assets);

    /// @notice Maximum assets `owner` may instantly redeem right now.
    function maxInstantRedeem(address vault, address owner) external view returns (uint128 assets);

    /// @notice The fee on an instant deposit, which the vault both previews and charges: one answer for both, so a
    ///         preview is the trade.
    /// @dev    A preview names no receiver, so for `previewDeposit`/`previewMint` and the `max*` views the vault passes
    ///         the account asking as both `sender` and `receiver`, and clamps a rebate to zero so a preview never
    ///         overstates. The trade passes its caller and receiver, and then calls `onInstantDeposit`.
    /// @param  vault The vault asking
    /// @param  sender The vault caller paying the assets
    /// @param  receiver The recipient of the minted shares
    /// @param  assets The gross amount the spread is charged on, or the net amount when `exactOut`
    /// @param  exactOut Whether `assets` is the net (the shares' value on `mint`), grossed up so the spread is at least
    ///         the configured rate of the gross
    /// @return feeAssets Entry fee taken before conversion. A negative fee is a rebate the vault pulls from
    ///         `feeRecipient` (which must have approved the vault) into the conversion
    /// @return feeRecipient Fee destination, or fee source when feeAssets is negative. With a zero recipient a
    ///         positive fee is retained: escrowed but backing no shares, so it accrues to the existing holders. A
    ///         rebate needs a nonzero recipient
    function quoteInstantDeposit(address vault, address sender, address receiver, uint128 assets, bool exactOut)
        external
        view
        returns (int128 feeAssets, address feeRecipient);

    /// @notice The fee on an instant redemption, which the vault both previews and charges.
    /// @dev    Same conventions as `quoteInstantDeposit`; the trade then calls `onInstantRedeem`.
    /// @param  vault The vault asking
    /// @param  sender The vault caller owning the burnt shares
    /// @param  receiver The recipient of the asset payout
    /// @param  assets The gross value of the shares burnt, or with `exactOut` the payout
    /// @param  exactOut Whether `assets` is the payout, grossed up so the spread is at least the configured rate
    /// @return feeAssets Exit fee deducted from the payout. A negative fee is a rebate paid by `feeRecipient` directly
    ///         to the receiver, outside the escrow
    /// @return feeRecipient Fee destination, or fee source when feeAssets is negative. With a zero recipient a
    ///         positive fee is retained: the shares burn at full value but the fee never leaves the escrow. A rebate
    ///         needs a nonzero recipient
    function quoteInstantRedeem(address vault, address sender, address receiver, uint128 assets, bool exactOut)
        external
        view
        returns (int128 feeAssets, address feeRecipient);

    /// @notice Instant deposit gating, called on the trade after its fee is quoted, with the same arguments. Reverts
    ///         to block. A policy may record the trade here (volume, timestamps); the fee is not asked again.
    function onInstantDeposit(address vault, address sender, address receiver, uint128 assets, bool exactOut) external;

    /// @notice Instant redeem gating, called on the trade after its fee is quoted, with the same arguments. Reverts to
    ///         block. The sender keys the redeem capacity.
    function onInstantRedeem(address vault, address sender, address receiver, uint128 assets, bool exactOut) external;

    /// @notice Whether `owner` may fund a position credited to `controller` when the caller does not act for the
    ///         controller: a request made for another controller, or a pending position handed to another holder.
    /// @dev    Asked by a vault with both lanes, where such a position holds the controller's instant lane closed until
    ///         it is settled and claimed. A caller that is the controller or its operator is never asked about.
    function canCredit(address vault, address owner, address controller) external view returns (bool);
}

/// @notice Default instant policy: a reserve cap on instant deposits, an on/off switch on instant
///         redemptions, optional basis-point fees, and an optional allowlist per lane, configured
///         per vault by the pool manager through the Envoy.
/// @dev    Redemptions have no volume cap: the escrow's available balance bounds them. A gated lane
///         allowlists who may *call* it (e.g. a front-door router), so the capacity views, which are
///         keyed by receiver, stay caller-agnostic. Who may *hold* shares is the transfer hook's job.
interface IReserveInstantPolicy is IInstantPolicy, IManagerCallFromHub {
    /// @notice Only the Envoy may configure the policy.
    error NotEnvoy();

    /// @notice The vault is not one of the configuring pool's vaults.
    error WrongPool();

    /// @notice A fee is not below 10_000 basis points.
    error InvalidFees();

    /// @notice The vault's instant redeem lane is gated and the caller is not allowed on it.
    error NotRedeemer();

    /// @notice The vault's instant deposit lane is gated and the caller is not allowed on it.
    error NotDepositor();

    /// @notice Configuration takes no native value.
    error UnexpectedValue();

    /// @notice Which facet of a vault's instant terms a `fromHub` payload carries. The payload is
    ///         `abi.encode(ConfigKind, address vault, bytes args)`, with `args` a {Config} for `Terms`
    ///         and `(address who, bool allowed)` for the allowlists.
    enum ConfigKind {
        Terms,
        /// @dev Who may call the instant deposit lane of a gated vault.
        Depositor,
        /// @dev Who may call the instant redeem lane of a gated vault.
        Redeemer,
        /// @dev Who may fund a position credited to a controller the caller does not act for.
        Sponsor
    }

    /// @notice Per-vault instant configuration.
    /// @dev Field order is load-bearing: the fee entrypoints read slot 0, `maxInstantDeposit` slot 1.
    struct Config {
        /// @dev Zero retains the fees in the escrow for the existing holders instead of paying them out.
        address feeRecipient;
        /// @dev Fee on an instant deposit, in basis points of the gross; strictly below 10_000.
        uint16 depositFeeBps;
        /// @dev Fee on an instant redemption, in basis points of the gross; strictly below 10_000.
        uint16 redeemFeeBps;
        /// @dev Whether instant redemptions are open.
        bool redeemEnabled;
        /// @dev Whether only allowlisted callers may use the instant deposit lane.
        bool gatedDeposit;
        /// @dev Whether only allowlisted callers may use the instant redeem lane.
        bool gatedRedeem;
        /// @dev Instant deposits are capped at this less the escrow's available balance; zero closes them.
        uint128 maxReserve;
    }

    /// @notice A vault's instant terms were set.
    event SetConfig(PoolId indexed poolId, address indexed vault, Config config);

    /// @notice `who` was added to or removed from one of a vault's allowlists.
    event SetAllowed(PoolId indexed poolId, address indexed vault, address indexed who, ConfigKind kind, bool allowed);

    /// @notice Whether `who` is on the vault's `kind` allowlist (never for `Terms`, which is no list).
    function isAllowed(address vault, ConfigKind kind, address who) external view returns (bool);

    /// @notice The instant configuration set for a vault.
    function config(address vault)
        external
        view
        returns (
            address feeRecipient,
            uint16 depositFeeBps,
            uint16 redeemFeeBps,
            bool redeemEnabled,
            bool gatedDeposit,
            bool gatedRedeem,
            uint128 maxReserve
        );
}

/// @notice Request keying and gating policy for a vault: names the bucket each async request joins, pending hub-side
///         settlement.
/// @dev    Required for async flows. Grouping models (per-investor, per-request, per-time-period) are policy
///         implementations, not vault logic. A policy names buckets by keys of its own; the vault maps each key to a
///         bucket and allocates the ids.
interface IRequestPolicy {
    /// @notice Request gating and bucket selection. Reverts to block.
    /// @dev    Every request under the same `key` and side joins one bucket, opened by the first. A zero key opens a
    ///         fresh bucket every time, and a batching policy may not answer it. A non-batching policy's key must be
    ///         the controller's alone (derived from it), since an unbatched bucket has one owner and is sealed once
    ///         sent; a request into another controller's reverts. `owner` is the payer, for policies that gate which
    ///         wallets may fund a position. A policy may record the request here, against the key: the vault's
    ///         `keyOf` maps a bucket's id back to it, so a policy that tags each request answers a fresh key of its
    ///         own instead of zero.
    /// @return key The bucket the request joins, or zero for a fresh one
    function onRequest(address vault, address controller, address owner, bool isDeposit, uint128 amount)
        external
        returns (bytes32 key);

    /// @notice Whether the policy batches no more requests under `key`, so the vault may send what it queued. Once
    ///         true it stays true for that key. Reverts to block.
    /// @dev    Asked only by a batching vault: by `flushRequest` before sending a batch, so a bucket's `total` is never
    ///         sealed while contributions can still arrive, and when a request opens a new batch on a side, about the
    ///         side's previous batch, which the vault then sends if it holds queued requests. A vault that does not
    ///         batch sends each request as it is made and never asks.
    function isClosed(address vault, bytes32 key) external view returns (bool);

    /// @notice The most buckets of one side a single controller can be adding to at once: 1 for a policy that
    ///         reuses or opens one bucket per request, more where a request can land in one of several open windows.
    /// @dev    Read once, from the vault's constructor, and fixed for the vault's life. The vault refuses a
    ///         configuration that tracks fewer of a controller's positions than this.
    function maxOpenBuckets() external view returns (uint256);

    /// @notice Whether requests wait in shared batches for `flushRequest`, rather than each being sent as it is made.
    /// @dev    Read once, from the vault's constructor, and fixed for the vault's life.
    function isBatched() external view returns (bool);

    /// @notice Whether pending requests may change hands (ERC-8161): the vault refuses every transfer otherwise, and
    ///         advertises the interfaces only when true.
    /// @dev    Read once, from the vault's constructor, and fixed for the vault's life. Who may transfer to whom, and
    ///         how much, is the share token's role hook's to gate (`DepositRequestTransfer`, `RedeemRequestTransfer`).
    function supportsTransfers() external view returns (bool);
}

/// @notice One hub settlement of a request: a fill of `assets` and `shares`, or a cancellation of `cancelledGross`, of
///         which `cancelledNet` went back to the contributors and the rest was kept as a fee. The figures of the
///         vault's `BucketSettled` event.
struct Settlement {
    uint128 assets;
    uint128 shares;
    uint128 cancelledGross;
    uint128 cancelledNet;
}

/// @notice Optional observer told about each settlement the vault applies.
/// @dev    Nullable on the vault. A revert fails the hub callback (retryable), so only revert to
///         block settlement on purpose; a best-effort observer must guard its own calls.
interface ISettlementObserver {
    /// @notice Called once per settlement of `requestId`, after the vault's state reflects it. Reverts to block.
    /// @param  requestId The bucket's request id, `vault << 96 | localId`
    function onSettle(address vault, uint256 requestId, bool isDeposit, Settlement calldata settlement) external;
}

/// @notice Optional third-party liquidity route between a vault and an external venue. The vault
///         pulls liquidity for instant redemptions through `provide` and offers fresh deposits
///         through `forward`.
/// @dev    `available` is advisory: overstating it makes the redemption revert inside `provide`.
///         The cost of provided liquidity is priced as an exit fee in the instant policy.
interface ILiquidityRoute {
    /// @notice Transfer `assets` to the vault, which forwards them into its escrow and accounts
    ///         them. All-or-nothing: reverts when the full amount cannot be provided.
    /// @dev    Paid to the vault, not the shared escrow, so delivery is measured on a balance only the
    ///         vault moves.
    function provide(address vault, uint128 assets) external;

    /// @notice Offer `assets` that have just entered the escrow to be routed into the venue.
    /// @dev    Called on instant issuance and async approval. Optional: a no-op leaves the assets
    ///         idle. A revert blocks the issuance or the settlement. A route that moves assets must
    ///         guard `msg.sender == vault`, as `provide` does.
    function forward(address vault, uint128 assets) external;

    /// @notice Assets the route can currently provide for this vault.
    /// @dev    SHOULD NOT revert: it backs `maxWithdraw`/`maxRedeem` and instant redemptions past the
    ///         escrow's balance, which revert with it.
    function available(address vault) external view returns (uint128 assets);
}
