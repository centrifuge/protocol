// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IVault} from "./IVault.sol";

import {D18} from "../../misc/types/D18.sol";
import {IERC7575} from "../../misc/interfaces/IERC7575.sol";
import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";
import {IERC7540Deposit, IERC7540Redeem, IERC7540Operator} from "../../misc/interfaces/IERC7540.sol";
import {IERC8161DepositTransferable, IERC8161RedeemTransferable} from "../../misc/interfaces/IERC8161.sol";

import {AssetId} from "../../core/types/AssetId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IVaultDepositCallbacks, IVaultRedeemCallbacks} from "../messaging/interfaces/IVaultRequestManager.sol";

import {IVaultOracle} from "../oracles/interfaces/IVaultOracle.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ISettlementObserver,
    ILiquidityRoute
} from "../policies/interfaces/IVaultPlugins.sol";

// The escrow reservation reasons a vault reserves under: one flat key for the redeem payout, and for a deposit
// the hash of this and the request's local id.
bytes32 constant REASON_REDEEM = bytes32(uint256(2));
bytes32 constant REASON_DEPOSIT = bytes32(uint256(1));

/// @notice Per-controller claimable ledger, in exact totals. Each side keeps both units of what was filled (a
///         deposit's shares and the assets they were filled for), since fills can come at different prices. A
///         claim in either unit converts pro-rata against that pair, and a claim of the whole balance pays exactly
///         what is left. Refunds from cancellations are kept apart, as they have no counterpart in the other unit.
/// @dev Pending amounts are derived from `BucketLib`, not stored here.
struct InvestmentState {
    /// @dev Shares claimable through `deposit()` or `mint()`
    uint128 depositShares;
    /// @dev The assets `depositShares` was filled for; a deposit claim converts pro-rata against it
    uint128 depositAssets;
    /// @dev Assets claimable through `withdraw()` or `redeem()`
    uint128 redeemAssets;
    /// @dev The shares `redeemAssets` was filled for; a redeem claim converts pro-rata against it
    uint128 redeemShares;
    /// @dev Shares returned by cancelled redemptions, claimable through `mint()` ahead of `depositShares`
    uint128 refundShares;
    /// @dev Assets returned by cancelled deposits, claimable through `withdraw()` ahead of `redeemAssets`
    uint128 refundAssets;
}

/// @notice A settlement bucket keyed by the local id assigned by the request policy (the full
///         ERC-7540 request id is `(vault address << 96) | localId`). Every async request is a
///         contribution to a bucket; fulfillments settle bucket-level and distribute pro-rata to
///         contributors. Owned and mutated by `BucketLib`.
/// @dev Field order is load-bearing: the queue and the denominator, the fills and the cancellations
///      each share a slot, and `flushed` keeps the last one non-zero from the flush on, so a settlement
///      bumping `settlements` never pays for a fresh slot (a redeem bucket's `isDeposit` is false).
struct Bucket {
    /// @dev Amount accumulated but not yet sent to the hub (spoke-side batching)
    uint128 queued;
    /// @dev Sum of all contributions; the pro-rata denominator
    uint128 total;
    /// @dev Cumulative fulfilled amounts across hub callbacks
    uint128 fulfilledAssets;
    uint128 fulfilledShares;
    /// @dev Cumulative cancelled amount, gross (assets for deposit buckets, shares for redeem
    ///      buckets). Retires what is outstanding and releases the request-time reservation.
    uint128 cancelledGross;
    /// @dev The same cancellation net of any cancellation fee, i.e. what the investor may claim. The
    ///      gross/net difference is the retained fee, which accretes to pool NAV.
    uint128 cancelledNet;
    /// @dev Whether the bucket tracks a deposit (assets) or redeem (shares) request
    bool isDeposit;
    /// @dev Sent to the hub at least once; closed to new contributors, except the sole owner (a
    ///      contributor who already owns the whole bucket) whose pro-rata ratio stays 1 regardless
    bool flushed;
    /// @dev Settlements applied so far, bumped once per {BucketLib.settle}. A contributor whose
    ///      {Contribution.foldedSettlements} still matches has nothing new to fold
    uint32 settlements;
    /// @dev The controller an unbatched bucket belongs to, whose slice each settlement folds at once; zero for a batch
    address owner;
}

/// @notice A single controller's stake in a bucket: what they contributed, and their already-folded
///         share of its settlement. Deleted once the bucket is fully settled and folded.
/// @dev Field order is load-bearing: an uncancelled fold touches only the first two of three slots.
struct Contribution {
    uint128 amount;
    /// @dev {Bucket.settlements} as of the last fold. Equal means nothing has settled since
    uint32 foldedSettlements;
    uint128 foldedAssets;
    uint128 foldedShares;
    /// @dev Net-denominated, matching {Bucket.cancelledNet}
    uint128 foldedCancelledNet;
    /// @dev Gross-denominated, matching {Bucket.cancelledGross}
    uint128 foldedCancelledGross;
}

/// @notice A controller's position as the views report it: what folding their horizon would credit per
///         direction, and what is still pending per side (the ERC-7540 `pending*Request(0)` aggregates).
struct UnfoldedState {
    uint128 depositShares;
    uint128 depositAssets;
    uint128 redeemShares;
    uint128 redeemAssets;
    uint128 refundShares;
    uint128 refundAssets;
    uint128 depositPending;
    uint128 redeemPending;
}

/// @notice The policy's answer for one instant trade: a positive fee with a recipient is a `charge`, a negative one
///         a `rebate`, and a positive fee with no recipient is `retained`. At most one of the three is non-zero.
struct InstantFee {
    uint128 charge;
    uint128 rebate;
    address recipient;
    uint128 retained;
}

/// @notice The five VDK plugins fixed per vault: pricing, instant capacity/fees, request
///         grouping, third-party liquidity, and settlement observation.
struct VaultPlugins {
    IVaultOracle oracle;
    IInstantPolicy instantPolicy;
    IRequestPolicy requestPolicy;
    ILiquidityRoute liquidityRoute;
    ISettlementObserver settlementObserver;
}

/// @notice Full vault configuration, fixed at deployment. To change any of it, deploy a new vault.
/// @dev `foldHorizon` is how many of a controller's latest positions per side a claim folds on its own, zero for
///      the default (see `IVaultBase.foldHorizon`).
struct VaultConfig {
    ISpoke spoke;
    ISpokeRegistry spokeRegistry;
    VaultPlugins plugins;
    uint256 foldHorizon;
}

/// @notice Everything the vault reverts with. Split from the function surface below so the settlement
///         libraries can raise them without inheriting the surface.
interface IVaultErrors {
    /// @notice A request or claim of zero.
    error ZeroAmount();
    /// @notice The caller may not request for that controller: it is not the owner or its operator, or not accepted.
    error NotSponsor();
    /// @notice A hub settlement exceeds what the bucket sent and has not had answered.
    error OverSettled();
    /// @notice The vault's prices are invalid or zero, so it cannot convert.
    error InvalidPrice();
    /// @notice The caller is neither the owner nor one of its operators.
    error InvalidOwner();
    /// @notice The bucket was sent to the hub, so only its sole owner may add to it.
    error BucketSealed();
    /// @notice A fill carries assets without shares, or shares without assets.
    error OneSidedFill();
    /// @notice The vault is not linked to its share class, so it cannot transact.
    error VaultNotLinked();
    /// @notice The request id names a bucket of the other side, or one owned by another controller.
    error RequestIdInUse();
    /// @notice The controller has no contribution in the bucket to transfer.
    error NoContribution();
    /// @notice The bucket has nothing queued to send to the hub.
    error NoQueuedRequest();
    /// @notice A cancellation credits more than it retires.
    error NetExceedsGross();
    /// @notice The request policy still accepts requests into the batch.
    error BucketStillOpen();
    /// @notice The sender's settled slice is not folded yet, its ledger having no room, so the request cannot move.
    error FoldDeferred();
    /// @notice A batching request policy answered the zero key, which names no batch it could close.
    error ZeroBatchKey();
    /// @notice The request policy does not let pending requests change hands.
    error TransfersUnsupported();
    /// @notice The request id belongs to another vault, or names no bucket on that side.
    error InvalidRequestId();
    /// @notice The bucket is on the other side, or has nothing outstanding to settle.
    error NoPendingRequest();
    /// @notice The bucket was never sent to the hub, so there is nothing to settle.
    error BucketNotFlushed();
    /// @notice The controller is zero, or the caller does not act for it.
    error InvalidController();
    /// @notice The request policy reports no open buckets, or the fold horizon is below them.
    error InvalidFoldHorizon();
    /// @notice The claim exceeds what the controller can claim on the redeem side.
    error ExceedsRedeemLimits();
    /// @notice The instant policy charged a fee with no recipient.
    error InvalidFeeRecipient();
    /// @notice The claim exceeds what the controller can claim on the deposit side.
    error ExceedsDepositLimits();
    /// @notice The escrow or the liquidity route cannot pay the assets out.
    error InsufficientLiquidity();
}

/// @notice Everything the vault emits beyond the ERC standards' events, declared apart from the function surface so
///         the settlement libraries can emit them without inheriting it.
/// @dev Events about one request lead with its `requestId`, indexed. Those whose name does not fix the side carry
///      `isDeposit`.
interface IVaultEvents {
    /// @notice A fold credited a deposit request's contribution with claimable shares for the controller.
    event DepositClaimable(uint256 indexed requestId, address indexed controller, uint256 assets, uint256 shares);

    /// @notice A fold credited a redeem request's contribution with claimable assets for the controller.
    event RedeemClaimable(uint256 indexed requestId, address indexed controller, uint256 assets, uint256 shares);

    /// @notice A cancelled deposit request's assets became claimable for the controller, through
    ///         the redeem side (`withdraw`/`redeem`). These are Centrifuge events, not ERC-7887's, which the vault
    ///         does not implement. `assets` is the net of the cancellation fee; the gross is in `RequestFolded`.
    event CancelDepositClaimable(uint256 indexed requestId, address indexed controller, uint256 assets);

    /// @notice A cancelled redeem request's shares became claimable for the controller, through
    ///         the deposit side (`mint`). `shares` is the net of the cancellation fee; the gross is in
    ///         `RequestFolded`.
    event CancelRedeemClaimable(uint256 indexed requestId, address indexed controller, uint256 shares);

    /// @notice A bucket's queued amount was sent to the hub as a request of `amount` (assets on the
    ///         deposit side, shares on the redeem side).
    event RequestFlushed(uint256 indexed requestId, bool isDeposit, uint128 amount);

    /// @notice A bucket was created, or reused after its sole owner retired it, by the first contribution to
    ///         `requestId`. A request id may be opened again after it was retired, so this marks each generation.
    ///         `key` is the request policy's name for it (a window, a controller), zero for a bucket per request.
    event BucketOpened(uint256 indexed requestId, bool isDeposit, bytes32 key);

    /// @notice The controller's position in `requestId` is outside its fold horizon, so a claim no longer folds it. In
    ///         a batch only `foldRequest(localId, controller)` credits what it settles from here; an unbatched bucket
    ///         (one with an `owner`) still folds as it settles, so a keeper can skip it, unless that fold was deferred for
    ///         a ledger counter without room (`BucketLib.foldInto`). Emitted when the horizon has
    ///         no room for a position the controller did not submit (a sponsor's, or one transferred to it), and when
    ///         the controller's own position evicts an older one the eviction's fold did not complete. A keeper tracks
    ///         these pairs, folds each on its bucket's `BucketSettled`, and drops one on its `RequestFolded` with
    ///         `completed`.
    event OutsideHorizon(uint256 indexed requestId, address indexed controller, bool isDeposit);

    /// @notice A controller's contribution to a bucket was folded, whether or not the fold credited anything. The
    ///         amounts are the slice the fold settled since the last one: `assets` and `shares` as credited to
    ///         the claimable ledger (zero when the slice floors to dust in the ledger's unit), `cancelledGross` as
    ///         retired from the pending and `cancelledNet` as credited to the refund balance, which differ by the
    ///         retained cancellation fee. `pending` is what the contribution still has outstanding, `completed`
    ///         that it is spent and deleted, and `retired` that it was the bucket's sole owner, so the id can be
    ///         reused. Beside it, the `*Claimable` events carry the credit.
    event RequestFolded(
        uint256 indexed requestId,
        address indexed controller,
        bool isDeposit,
        uint128 assets,
        uint128 shares,
        uint128 cancelledGross,
        uint128 cancelledNet,
        uint128 pending,
        bool completed,
        bool retired
    );

    /// @notice A pending position moved to a new controller, beside the standard ERC-8161 transfer event, which
    ///         carries no amounts. `contributed` is the whole contribution that moved and `pending` the unsettled part
    ///         of it at the transfer. The receiver's next fold reports what it gains in its `RequestFolded`.
    event RequestTransferred(
        uint256 indexed requestId,
        address indexed from,
        address indexed to,
        bool isDeposit,
        uint128 contributed,
        uint128 pending
    );

    /// @notice A claim paid out of the controller's claimable ledger, beside its ERC-4626 `Deposit` or `Withdraw`
    ///         event, which an instant trade emits too. `refund` is the part taken from the refund balance:
    ///         shares on `mint`, assets on `withdraw`, and zero on `deposit` and `redeem`.
    /// @dev The ledger is per controller, so a claim names no request id: the ledger pays pro-rata across everything
    ///      the controller was credited. A claim of refunds only (`mint` with refunded shares alone, `withdraw` with
    ///      refunded assets alone) still emits the standard event with the other leg zero, which reads as a free
    ///      deposit or withdrawal. Indexers tell the two apart by `refund`.
    event Claimed(
        address indexed controller,
        address indexed receiver,
        address sender,
        bool isDeposit,
        uint128 assets,
        uint128 shares,
        uint128 refund
    );

    /// @notice A hub callback settled a bucket, as a fill or as a cancellation, with the amounts of the other
    ///         zero. Contributors' slices are pro-rata to their contributions, so an indexer can derive each
    ///         one's claimable from this and the request events without waiting for a fold. A callback that settles
    ///         nothing is accepted and emits it with all amounts zero.
    /// @dev    What a deposit's approval or cancellation released from the request's reservation, which a manager's
    ///         early unreserve can make less than the callback's amount, is the escrow's `DecreaseReserve` under the
    ///         request's reason (`keccak256(abi.encode(REASON_DEPOSIT, localId))`).
    event BucketSettled(
        uint256 indexed requestId,
        bool isDeposit,
        uint128 assets,
        uint128 shares,
        uint128 cancelledGross,
        uint128 cancelledNet
    );

    /// @notice The pricing of an instant deposit or redemption, beside its ERC-4626 event: the fee
    ///         paid to (or rebate from) `feeRecipient`, the leg retained by the pool, and on a
    ///         redemption what was drawn from the liquidity route: the shortfall, plus what a manager reserved
    ///         beyond the escrow's total, which the draw meets first. `caller` is the account that traded,
    ///         `shares` the shares minted or burnt, and the prices those the trade converted at.
    event InstantFees(
        address indexed caller,
        address indexed receiver,
        bool isDeposit,
        uint128 shares,
        int128 feeAssets,
        address feeRecipient,
        uint128 retainedAssets,
        uint128 routedAssets,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare
    );

    /// @notice The vault offered `assets` of fresh deposits to its liquidity route. `requestId` is the approved
    ///         request, or zero when the assets came from an instant deposit.
    event ForwardedToRoute(address indexed route, uint256 indexed requestId, uint128 assets);
}

/// @notice The shared vault surface: identity, configuration, operator management and request transport. The
///         deposit and redeem flow surfaces are declared separately, in the ERC-7540 interfaces and the settlement
///         callbacks.
interface IVaultBase is IVault, IERC7540Operator, IVaultErrors, IVaultEvents {
    /// @notice Sends a bucket's queued amount to the hub and closes it to new contributors except its
    ///         sole owner. Permissionless; on a batching vault the request policy's `isClosed` gates an open batch.
    function flushRequest(uint96 localId) external;

    /// @notice The asset id for this vault.
    function assetId() external view returns (AssetId);

    /// @notice The spoke this vault transacts through.
    function spoke() external view returns (ISpoke);

    /// @notice The escrow holding this vault's assets, parked shares and reservations.
    function escrow() external view returns (address);

    /// @notice The registry the vault reads linkage, prices and the request manager from.
    function spokeRegistry() external view returns (ISpokeRegistry);

    /// @notice Oracle for vault pricing.
    function oracle() external view returns (IVaultOracle);

    /// @notice Instant capacity and fee policy. Unset disables instant deposits/redeems.
    function instantPolicy() external view returns (IInstantPolicy);

    /// @notice Request keying and gating policy. Required for async flows.
    function requestPolicy() external view returns (IRequestPolicy);

    /// @notice Optional settlement observer, notified after hub callbacks are applied.
    function settlementObserver() external view returns (ISettlementObserver);

    /// @notice Optional third-party liquidity route for instant redemptions.
    function liquidityRoute() external view returns (ILiquidityRoute);

    /// @notice How many of a controller's latest positions per side a claim folds on its own (the fold horizon). A
    ///         new position takes a slot, the oldest making way when it is full. A position outside it folds as it
    ///         settles if unbatched, and a batch waits for `foldRequest`; `OutsideHorizon` names each.
    /// @dev Set at deployment, at least the request policy's `maxOpenBuckets` (`InvalidFoldHorizon`), which is also
    ///      the default. A batching pool whose investors wait on closed but unsettled batches configures more. A
    ///      position the controller did not request themselves (a sponsor's, or one transferred in) never takes a slot
    ///      kept for their open buckets, so their request never evicts an open one. A claim costs a fold per entry
    ///      held, not per slot, and settling an unbatched bucket rewrites its owner's horizon, so a large horizon can
    ///      need the manager's `extraGasLimit` on the callback.
    function foldHorizon() external view returns (uint256);

    /// @notice The shares `mint` could claim for `controller` now, refunds from cancelled redemptions included.
    ///         Unlike `maxMint`, it is a claim whatever lane a call would take: it never reads the instant
    ///         lane's capacity. Includes what folding the controller's horizon would credit.
    function claimableMint(address controller) external view returns (uint256 shares);

    /// @notice The assets `withdraw` could claim for `controller` now, refunds from cancelled deposits
    ///         included. The redeem-side twin of {claimableMint}.
    function claimableWithdraw(address controller) external view returns (uint256 assets);

    /// @notice The settlement bucket for a local request id.
    function bucket(uint96 localId) external view returns (Bucket memory);

    /// @notice The bucket the request policy's `key` names on one side, zero before its first request and once an
    ///         unbatched bucket under it changes hands.
    function bucketOf(bytes32 key, bool isDeposit) external view returns (uint96 localId);

    /// @notice The key a bucket was opened under, zero for a bucket a zero key opened. A batching vault asks the
    ///         policy's `isClosed` about it before sending the batch; an observer maps a settled `requestId` back to
    ///         the key its policy answered. Kept after the key stops naming the bucket, as once an unbatched bucket
    ///         changes hands.
    function keyOf(uint96 localId) external view returns (bytes32 key);

    /// @notice A controller's stake in a bucket, deleted once fully folded.
    function contribution(uint96 localId, address controller) external view returns (Contribution memory);
}

/// @notice The 2-argument claim entrypoints, in their own interface so `.selector` is unambiguous
///         beside IERC7575's 3-argument overloads.
interface IVaultTwoArgClaims {
    /// @notice 2-arg withdraw: async claim when the caller has something claimable or a redeem request pending,
    ///         instant redemption otherwise.
    function withdraw(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice 2-arg redeem: routes like {withdraw}.
    function redeem(uint256 shares, address receiver) external returns (uint256 assets);
}

/// @notice The full vault ABI. The async and instant flows are described in `src/vaults/ARCHITECTURE.md`.
/// @dev How the ERC-4626 surface reads on this vault:
///      - The 2-arg `deposit`/`mint`/`withdraw`/`redeem` claim asynchronously when the caller has something
///        claimable or a request pending on that side, and settle instantly otherwise.
///      - The 3-arg forms route like the 2-arg ones when the caller is the controller (the owner, for
///        `withdraw`/`redeem`, as ERC-4626 requires), and only claim for an operator: the instant path pulls
///        from or burns the caller, so an operator acting for an idle controller can never reach it.
///      - `max*` report what is claimable, or the instant capacity when nothing is in flight; the
///        instant `maxWithdraw`/`maxRedeem` are also bounded by the owner's share balance.
///        `claimable*Request` report only what the hub fulfilled, with no hook gate, so they never revert.
///      - `convertTo*` and `totalAssets` convert at the last hub prices; they are not previews.
///      - `supportsInterface` always claims ERC-7575, ERC-165 and the operator interface, and the
///        async ERC-7540 interfaces only when a request policy is set, so an instant-only vault does not
///        claim interfaces whose `request*` methods it would reject.
///      - Request ids are `(vault address << 96) | localId`, so parallel vaults never collide.
interface IAsyncVault is
    IVaultTwoArgClaims,
    IVaultBase,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks,
    IERC7540Deposit,
    IERC7540Redeem,
    IERC8161DepositTransferable,
    IERC8161RedeemTransferable,
    IERC7575,
    IRecoverable
{
    /// @notice Folds one contributor's pro-rata slice of a bucket's settlements (rounded down) into
    ///         their claimable ledger, which is when it becomes claimable. Permissionless and incremental;
    ///         a settlement folds an unbatched bucket, and claims only the controller's latest positions (the
    ///         vault's `foldHorizon`).
    function foldRequest(uint96 localId, address controller) external;

    /// @notice Price of 1 unit of share in asset decimals.
    function pricePerShare() external view returns (uint256);

    /// @notice `maxWithdraw` without its bound by the owner's share balance: what `owner` could withdraw
    ///         now if it held the shares. For a caller sizing a redemption before it holds them.
    function withdrawCapacity(address owner) external view returns (uint256);
}
