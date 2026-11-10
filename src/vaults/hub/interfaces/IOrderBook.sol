// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRequestObserver} from "./IRequestObserver.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {RequestId} from "../../../core/types/RequestId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";
import {IHubRequestManagerCallback} from "../../../core/hub/interfaces/IHubRequestManagerCallback.sol";

/// @notice Manager action decoded from the `fromHub` payload, `abi.encode(action, args)` with `args` a
///         {Fulfillment}, a {Cancellation} or, for `SetObserver`, an observer address.
enum OrderBookAction {
    Invalid,
    Fulfill,
    Cancel,
    SetObserver
}

/// @notice `Fulfill` action arguments. `extraGasLimit` is added to the settlement callback's budget, so a
///         pool whose spoke side runs more than the benchmark (a heavy hook, observer or route) can fund it.
struct Fulfillment {
    bool isDeposit;
    ShareClassId scId;
    AssetId assetId;
    RequestId requestId;
    uint128 fill;
    uint128 net;
    D18 pricePoolPerAsset;
    D18 pricePoolPerShare;
    uint128 extraGasLimit;
    address refund;
}

/// @notice `Cancel` action arguments. `net` may not exceed `amount`: a cancellation can retain a fee but
///         never credit more than the order it retires. `extraGasLimit` as in {Fulfillment}.
struct Cancellation {
    bool isDeposit;
    ShareClassId scId;
    AssetId assetId;
    RequestId requestId;
    uint128 amount;
    uint128 net;
    uint128 extraGasLimit;
    address refund;
}

/// @notice Minimal hub-side request manager. Each spoke request is an independent order that
///         auto-approves on receipt; the manager then fulfills (issue on deposit, revoke on redeem) or
///         cancels it, supplying the prices and the net amount explicitly. `net < fill` is a fee the
///         pool retains, `net > fill` a rebate it pre-funds; a cancellation never rebates. The pool
///         policy bounds both; fee logic lives in a wrapping manager such as {FeeRequestManager}.
///         An optional per-pool {IRequestObserver} is notified on arrival; a revert fails the request message
///         (retryable) and it cannot change the order.
/// @dev    Implements the {IHubRequestManager} (`request`) call surface without advertising ERC-165.
interface IOrderBook is IManagerCallFromHub {
    // Events
    // The events index the pool, share class and asset. A request id is not indexed (three topics at most), but its
    // top 160 bits are the vault, so an indexer joins a vault's orders on the data field.
    event SetObserver(PoolId indexed poolId, address observer);
    event DepositRequested(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, RequestId requestId, uint128 amount
    );
    event RedeemRequested(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, RequestId requestId, uint128 amount
    );
    event Fulfill(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 fillAmount,
        uint128 netAmount,
        uint128 outputAmount,
        D18 pricePoolPerAsset,
        D18 pricePoolPerShare
    );
    event Cancel(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 amount,
        uint128 netAmount
    );

    // Errors
    error NotEnvoy();
    error ZeroAmount();
    error UnknownAction();
    error UnexpectedValue();
    error NetExceedsGross();
    error InsufficientOutstanding();

    /// @notice Handles a request forwarded from the Hub (spoke-initiated). See {IHubRequestManager}.
    /// @dev    The request id is the message's leading word, namespaced by the vault spoke-side.
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;

    /// @notice Batch body of the `Fulfill` action. Only reachable as the gateway's callback into the
    ///         OrderBook, inside the batch `fromHub` opens.
    function fulfillCallback(PoolId poolId, Fulfillment calldata f) external;

    /// @notice The Hub callback the manager sends outbound messages through.
    function hub() external view returns (IHubRequestManagerCallback);

    /// @notice The optional per-pool request observer.
    function observer(PoolId poolId) external view returns (IRequestObserver);

    /// @notice The outstanding deposit order for a request id.
    function depositOrders(PoolId poolId, ShareClassId scId, AssetId assetId, RequestId requestId)
        external
        view
        returns (uint128 outstanding);

    /// @notice The outstanding redeem order for a request id.
    function redeemOrders(PoolId poolId, ShareClassId scId, AssetId assetId, RequestId requestId)
        external
        view
        returns (uint128 outstanding);
}
