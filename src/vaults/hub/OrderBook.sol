// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRequestObserver} from "./interfaces/IRequestObserver.sol";
import {IOrderBook, OrderBookAction, Fulfillment, Cancellation} from "./interfaces/IOrderBook.sol";

import {Auth} from "../../misc/Auth.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {RequestId} from "../../core/types/RequestId.sol";
import {PricingLib} from "../../core/libraries/PricingLib.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../core/utils/BatchedMulticall.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {IHubRequestManagerCallback} from "../../core/hub/interfaces/IHubRequestManagerCallback.sol";

import {RequestMessageLib} from "../messaging/libraries/RequestMessageLib.sol";
import {RequestCallbackMessageLib} from "../messaging/libraries/RequestCallbackMessageLib.sol";

/// @title  OrderBook
/// @notice Minimal hub-side request manager: each spoke request is an independent order that
///         auto-approves on receipt, and the manager fulfills or cancels it.
contract OrderBook is Auth, BatchedMulticall, IOrderBook {
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    address public immutable envoy;
    IHubRegistry public immutable hubRegistry;
    IHubRequestManagerCallback public immutable hub;

    mapping(PoolId => IRequestObserver) public observer;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(RequestId => uint128)))) public redeemOrders;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(RequestId => uint128)))) public depositOrders;

    constructor(
        IHubRegistry hubRegistry_,
        IHubRequestManagerCallback hub_,
        IGateway gateway_,
        address envoy_,
        address deployer
    ) Auth(deployer) BatchedMulticall(gateway_) {
        hub = hub_;
        envoy = envoy_;
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Incoming requests
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOrderBook
    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external auth {
        (bool isDeposit, RequestId requestId, uint128 amount) = payload.deserializeRequest();
        (isDeposit ? depositOrders : redeemOrders)[poolId][scId][assetId][requestId] += amount;

        if (isDeposit) emit DepositRequested(poolId, scId, assetId, requestId, amount);
        else emit RedeemRequested(poolId, scId, assetId, requestId, amount);

        IRequestObserver obs = observer[poolId];
        if (address(obs) != address(0)) obs.onRequest(poolId, scId, assetId, requestId, isDeposit, amount);
    }

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable protected {
        require(msg.sender == envoy, NotEnvoy());
        // Decoded as a uint8, which reverts on a word that is not one rather than truncating it into a valid action
        OrderBookAction action = OrderBookAction(abi.decode(payload, (uint8)));

        if (action == OrderBookAction.Fulfill) return _fulfill(poolId, payload);
        if (action == OrderBookAction.Cancel) return _cancel(poolId, payload);
        if (action == OrderBookAction.SetObserver) return _setObserver(poolId, payload);
        revert UnknownAction();
    }

    /// @inheritdoc IOrderBook
    /// @dev Sends one settlement callback so the legs cannot land apart. The output is converted from `net`, so a
    ///      fee surfaces as fewer shares or assets for the same fill.
    function fulfillCallback(PoolId poolId, Fulfillment calldata f) external {
        gateway.lockCallback();
        require(f.fill > 0, ZeroAmount());
        _close(poolId, f.scId, f.assetId, f.requestId, f.isDeposit, f.fill);

        uint128 output = _convert(poolId, f);
        // A fill converting to nothing would be a callback the vault rejects and no retry can apply.
        require(output > 0, ZeroAmount());

        emit Fulfill(
            poolId,
            f.scId,
            f.assetId,
            f.requestId,
            f.isDeposit,
            f.fill,
            f.net,
            output,
            f.pricePoolPerAsset,
            f.pricePoolPerShare
        );
        bytes memory callback = f.isDeposit
            ? RequestCallbackMessageLib.SettledDeposit(f.requestId, f.fill, output).serialize()
            : RequestCallbackMessageLib.SettledRedeem(f.requestId, output, f.fill).serialize();
        _send(poolId, f.scId, f.assetId, callback, f.extraGasLimit, f.refund);
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev Auto-approves an order and notifies the observer.
    function _fulfill(PoolId poolId, bytes calldata payload) internal {
        (, Fulfillment memory f) = abi.decode(payload, (uint8, Fulfillment));
        gateway.withBatch{value: msgValue()}(abi.encodeCall(IOrderBook.fulfillCallback, (poolId, f)), f.refund);
    }

    /// @dev `net > amount` is rejected whatever the policy says: it would be paid out of other
    ///      investors' escrowed funds.
    function _cancel(PoolId poolId, bytes calldata payload) internal {
        (, Cancellation memory c) = abi.decode(payload, (uint8, Cancellation));
        require(c.amount > 0, ZeroAmount());
        require(c.net <= c.amount, NetExceedsGross());
        _close(poolId, c.scId, c.assetId, c.requestId, c.isDeposit, c.amount);

        emit Cancel(poolId, c.scId, c.assetId, c.requestId, c.isDeposit, c.amount, c.net);
        bytes memory callback = c.isDeposit
            ? RequestCallbackMessageLib.CancelledDeposit(c.requestId, c.amount, c.net).serialize()
            : RequestCallbackMessageLib.CancelledRedeem(c.requestId, c.amount, c.net).serialize();
        _send(poolId, c.scId, c.assetId, callback, c.extraGasLimit, c.refund);
    }

    function _setObserver(PoolId poolId, bytes calldata payload) internal {
        require(msgValue() == 0, UnexpectedValue());
        (, address obs) = abi.decode(payload, (uint8, address));
        observer[poolId] = IRequestObserver(obs);
        emit SetObserver(poolId, obs);
    }

    /// @dev Retires `amount` of an order, which may not exceed what is still outstanding.
    function _close(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        RequestId requestId,
        bool isDeposit,
        uint128 amount
    ) internal {
        mapping(RequestId => uint128) storage orders = (isDeposit ? depositOrders : redeemOrders)[poolId][scId][assetId];
        require(orders[requestId] >= amount, InsufficientOutstanding());
        orders[requestId] -= amount;
    }

    /// @dev Converts `net` at the supplied prices: assets to shares on a deposit, shares to assets on a
    ///      redeem. Zero at a zero share price.
    function _convert(PoolId poolId, Fulfillment calldata f) internal view returns (uint128) {
        if (f.pricePoolPerShare.isZero()) return 0;
        return f.isDeposit
            ? PricingLib.assetToShareAmount(
                f.net,
                hubRegistry.decimals(f.assetId),
                hubRegistry.decimals(poolId),
                f.pricePoolPerAsset,
                f.pricePoolPerShare,
                MathLib.Rounding.Down
            )
            : PricingLib.shareToAssetAmount(
                f.net,
                hubRegistry.decimals(poolId),
                hubRegistry.decimals(f.assetId),
                f.pricePoolPerShare,
                f.pricePoolPerAsset,
                MathLib.Rounding.Down
            );
    }

    function _send(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes memory payload,
        uint128 extraGasLimit,
        address refund
    ) internal {
        hub.requestCallback{value: msgValue()}(poolId, scId, assetId, payload, extraGasLimit, false, refund);
    }
}
