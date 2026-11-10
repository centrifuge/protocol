// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {RequestId} from "../../../core/types/RequestId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";
import {IBatchedMulticall} from "../../../core/utils/interfaces/IBatchedMulticall.sol";

/// @notice Config action decoded from the `fromHub` payload, `abi.encode(uint8 action, uint128 assetId,
///         uint16 feeBps)`. Through the Envoy so the pool's policy can delay a rate change.
enum FeeManagerAction {
    Invalid,
    SetFee
}

/// @notice A wrapping manager over the {OrderBook}: it fulfills at the pool's committed prices net of a
///         per-asset fee, which accretes to NAV. Callable by the pool's managers; the pool's policy is
///         asked about the original caller too, so only calls it would let that caller make instantly
///         pass. Out-of-policy calls go to the OrderBook directly, through the timelock.
interface IFeeRequestManager is IManagerCallFromHub, IBatchedMulticall {
    event SetFee(PoolId indexed poolId, AssetId indexed assetId, uint16 feeBps);

    /// @notice `caller`, a manager of the pool, fulfilled a request taking `feeBps` of `fillAmount`, which leaves
    ///         `netAmount` to convert. Both are in the order's own unit: assets on a deposit, shares on a redemption.
    ///         Emitted beside the order book's `Fulfill`, which carries the prices.
    event FeeCharged(
        PoolId indexed poolId,
        RequestId indexed requestId,
        address caller,
        bool isDeposit,
        uint128 fillAmount,
        uint128 netAmount,
        uint16 feeBps
    );

    error NotEnvoy();
    error NotManager();
    error FeeTooHigh();
    error NotInPolicy();
    error UnknownAction();
    error UnexpectedValue();
    error HoldingNotInitialized();

    /// @notice Percentage fee, in basis points, taken at fulfillment for a pool's asset lane.
    function feeBps(PoolId poolId, AssetId assetId) external view returns (uint16);

    /// @notice Fulfill an order net of the per-asset fee, at the committed prices: issue shares on a
    ///         deposit (`isDeposit`), revoke shares on a redeem.
    /// @param  fillAmount The part of the order filled, in the order's native unit
    /// @param  extraGasLimit Added to the settlement callback's budget, paid from `msg.value`
    /// @param  refund Receives the unspent part of `msg.value`
    function fulfill(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 fillAmount,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Cancel part of an outstanding order, refunding the investor: a deposit (`isDeposit`) or a
    ///         redeem.
    /// @param  amount The part of the order cancelled, in the order's native unit
    /// @param  extraGasLimit Added to the cancellation callback's budget, paid from `msg.value`
    /// @param  refund Receives the unspent part of `msg.value`
    function cancel(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable;
}
