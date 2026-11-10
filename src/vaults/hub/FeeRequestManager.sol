// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFeeRequestManager, FeeManagerAction} from "./interfaces/IFeeRequestManager.sol";
import {IOrderBook, OrderBookAction, Fulfillment, Cancellation} from "./interfaces/IOrderBook.sol";

import {D18} from "../../misc/types/D18.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {RequestId} from "../../core/types/RequestId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHubPolicy} from "../../core/utils/interfaces/IPolicy.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @title  FeeRequestManager
/// @notice Reference wrapping manager over the {OrderBook}, holding the fee policy the OrderBook
///         deliberately does not: a per-asset percentage fee taken at fulfillment.
/// @dev    A manager fills many orders in one `multicall`, which opens one gateway batch: every fill's settlement
///         callback joins it, so N fills are one message per destination. The functions the multicall runs read the
///         caller with `msgSender()` and the value with `msgValue()`.
contract FeeRequestManager is BatchedMulticall, IFeeRequestManager {
    using MathLib for *;
    using CastLib for address;

    IHub public immutable hub;
    address public immutable envoy;
    IOrderBook public immutable orderBook;
    uint16 public immutable localCentrifugeId;

    mapping(PoolId => mapping(AssetId => uint16)) public feeBps;

    constructor(IHub hub_, IOrderBook orderBook_, address envoy_, IGateway gateway_) BatchedMulticall(gateway_) {
        hub = hub_;
        orderBook = orderBook_;
        envoy = envoy_;
        localCentrifugeId = hub_.sender().localCentrifugeId();
    }

    modifier onlyManager(PoolId poolId) {
        require(hub.hubRegistry().manager(poolId, msgSender()), NotManager());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());
        (uint8 kind, AssetId assetId, uint16 feeBps_) = abi.decode(payload, (uint8, AssetId, uint16));
        require(kind == uint8(FeeManagerAction.SetFee), UnknownAction());
        // At 100% the net is zero: a fulfillment would consume the whole fill and credit nothing.
        require(feeBps_ < MathLib.BPS, FeeTooHigh());
        feeBps[poolId][assetId] = feeBps_;
        emit SetFee(poolId, assetId, feeBps_);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IFeeRequestManager
    function fulfill(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 fillAmount,
        uint128 extraGasLimit,
        address refund
    ) external payable onlyManager(poolId) {
        // Without a holding the hub prices the asset at 1.0, which a fill must not take as a price
        require(hub.holdings().isInitialized(poolId, scId, assetId), HoldingNotInitialized());

        uint16 bps = feeBps[poolId][assetId];
        uint128 net = _applyFee(fillAmount, bps);
        D18 pricePoolPerAsset = hub.pricePoolPerAsset(poolId, scId, assetId);
        (D18 pricePoolPerShare,) = hub.shareClassManager().pricePoolPerShare(poolId, scId);
        Fulfillment memory f = Fulfillment({
            isDeposit: isDeposit,
            scId: scId,
            assetId: assetId,
            requestId: requestId,
            fill: fillAmount,
            net: net,
            pricePoolPerAsset: pricePoolPerAsset,
            pricePoolPerShare: pricePoolPerShare,
            extraGasLimit: extraGasLimit,
            refund: refund
        });
        _callOrderBook(poolId, abi.encode(OrderBookAction.Fulfill, f), refund);
        emit FeeCharged(poolId, requestId, msgSender(), isDeposit, fillAmount, net, bps);
    }

    /// @inheritdoc IFeeRequestManager
    function cancel(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable onlyManager(poolId) {
        // No cancellation fee: the net is the whole amount
        Cancellation memory c = Cancellation({
            isDeposit: isDeposit,
            scId: scId,
            assetId: assetId,
            requestId: requestId,
            amount: amount,
            net: amount,
            extraGasLimit: extraGasLimit,
            refund: refund
        });
        _callOrderBook(poolId, abi.encode(OrderBookAction.Cancel, c), refund);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev The Hub sees this contract as the caller, so the policy is first asked about the same call
    ///      as if the original manager made it: only an instant, in-policy call passes.
    function _callOrderBook(PoolId poolId, bytes memory payload, address refund) internal {
        bytes32 target = address(orderBook).toBytes32();
        IHubPolicy policy = hub.policy(poolId);
        if (address(policy) != address(0)) {
            bytes memory data =
                abi.encodeCall(IHub.managerCall, (poolId, localCentrifugeId, target, payload, 0, msgValue(), refund));
            require(policy.authorizationDelay(poolId, msgSender(), data) == 0, NotInPolicy());
        }

        hub.managerCall{value: msgValue()}(poolId, localCentrifugeId, target, payload, 0, msgValue(), refund);
    }

    /// @dev Rounds the fee up: floored, it is zero for every fill below `BPS / bps`.
    function _applyFee(uint128 fillAmount, uint16 bps) internal pure returns (uint128) {
        return fillAmount - fillAmount.fractionOf(bps, MathLib.BPS, MathLib.Rounding.Up).toUint128();
    }
}
