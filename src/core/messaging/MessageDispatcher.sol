// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "./interfaces/IGateway.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IScheduleAuth} from "./interfaces/IScheduleAuth.sol";
import {IMessageDispatcher} from "./interfaces/IMessageDispatcher.sol";
import {MessageLib, VaultUpdateKind, ManagerKind} from "./libraries/MessageLib.sol";
import {ISpokeMessageSender, IHubMessageSender, IScheduleAuthMessageSender} from "./interfaces/IGatewaySenders.sol";
import {ISpokeGatewayHandler, IBalanceSheetGatewayHandler, IHubGatewayHandler} from "./interfaces/IGatewayHandlers.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {IEnvoy} from "../utils/interfaces/IEnvoy.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";

/// @title  MessageDispatcher
/// @notice This contract serializes and dispatches outgoing cross-chain messages, handling both local and
///         remote destinations by either directly invoking local handlers or routing through the gateway.
contract MessageDispatcher is Auth, IMessageDispatcher {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    uint16 public immutable localCentrifugeId;

    IEnvoy public envoy;
    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    ISpokeGatewayHandler public spokeHandler;
    IScheduleAuth public immutable scheduleAuth;
    IHubGatewayHandler public hubHandler;
    IBalanceSheetGatewayHandler public balanceSheet;

    constructor(uint16 localCentrifugeId_, IScheduleAuth scheduleAuth_, IGateway gateway_, address deployer)
        Auth(deployer)
    {
        localCentrifugeId = localCentrifugeId_;
        scheduleAuth = scheduleAuth_;
        gateway = gateway_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageDispatcher
    function file(bytes32 what, address data) external auth {
        if (what == "envoy") envoy = IEnvoy(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else if (what == "spokeHandler") spokeHandler = ISpokeGatewayHandler(data);
        else if (what == "hubHandler") hubHandler = IHubGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubMessageSender
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId, address refund) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.addPool(poolId);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(centrifugeId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize(), false, refund);
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyShareClass(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook,
        address refund
    ) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.addShareClass(poolId, scId, name, symbol, decimals, salt, hook.toAddress());
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.NotifyShareClass({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        name: name,
                        symbol: symbol.toBytes32(),
                        decimals: decimals,
                        salt: salt,
                        hook: hook
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        address refund
    ) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.updateShareMetadata(poolId, scId, name, symbol);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.NotifyShareMetadata({
                        poolId: poolId.raw(), scId: scId.raw(), name: name, symbol: symbol.toBytes32()
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateShareHook(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 hook, address refund)
        external
        payable
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.updateShareHook(poolId, scId, hook.toAddress());
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.UpdateShareHook({poolId: poolId.raw(), scId: scId.raw(), hook: hook}).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyPricePoolPerShare(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        D18 pricePoolPerShare,
        uint64 computedAt,
        address refund
    ) external payable auth {
        if (chainId == localCentrifugeId) {
            spokeHandler.updatePricePoolPerShare(poolId, scId, pricePoolPerShare, computedAt);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                chainId,
                MessageLib.NotifyPricePoolPerShare({
                        poolId: poolId.raw(), scId: scId.raw(), price: pricePoolPerShare.raw(), timestamp: computedAt
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyPricePoolPerAsset(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        D18 pricePoolPerAsset,
        address refund
    ) external payable auth {
        uint64 timestamp = block.timestamp.toUint64();
        if (assetId.centrifugeId() == localCentrifugeId) {
            spokeHandler.updatePricePoolPerAsset(poolId, scId, assetId, pricePoolPerAsset, timestamp);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                assetId.centrifugeId(),
                MessageLib.NotifyPricePoolPerAsset({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        assetId: assetId.raw(),
                        price: pricePoolPerAsset.raw(),
                        timestamp: timestamp
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateRestriction(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.updateRestriction(poolId, scId, payload);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.UpdateRestriction({
                        poolId: poolId.raw(), scId: scId.raw(), extraGasLimit: extraGasLimit, payload: payload
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendManagerHubCall(
        uint16 centrifugeId,
        PoolId poolId,
        address target,
        bytes calldata payload,
        uint128 extraGasLimit,
        uint256 value,
        address refund
    ) external payable auth {
        // `target` is explicit: a `fromHub` manager, or the ContractUpdaterForwarder for a wrapped contract
        // update. No origin args: already authorized at the Hub.
        if (centrifugeId == localCentrifugeId) {
            envoy.callFromHub{value: value}(poolId, target, payload);
            // Refund any value not forwarded rather than assume `value == msgValue()`: if that Hub
            // precondition ever changes, the remainder is returned instead of silently stranded here.
            SafeTransferLib.safeTransferETH(refund, msg.value - value);
        } else {
            _send(
                centrifugeId,
                MessageLib.ManagerCall({
                        poolId: poolId.raw(), target: target.toBytes32(), extraGasLimit: extraGasLimit, payload: payload
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            spokeHandler.updateVault(poolId, scId, assetId, vaultOrFactory.toAddress(), kind);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                assetId.centrifugeId(),
                MessageLib.UpdateVault({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        assetId: assetId.raw(),
                        vaultOrFactory: vaultOrFactory,
                        kind: uint8(kind),
                        extraGasLimit: extraGasLimit
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendSetRequestManager(uint16 centrifugeId, PoolId poolId, bytes32 manager, address refund)
        external
        payable
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            spokeHandler.setRequestManager(poolId, IRequestManager(manager.toAddress()));
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.SetRequestManager({poolId: poolId.raw(), manager: manager}).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateManager(
        uint16 centrifugeId,
        PoolId poolId,
        ManagerKind kind,
        bytes32 who,
        bool canManage,
        address refund
    ) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            address whoAddr = who.toAddress();
            if (kind == ManagerKind.BalanceSheet) balanceSheet.updateManager(poolId, whoAddr, canManage);
            else if (kind == ManagerKind.Adapter) multiAdapter.updateManager(poolId, whoAddr, canManage);
            else if (kind == ManagerKind.Gateway) gateway.updateManager(poolId, whoAddr, canManage);
            else if (kind == ManagerKind.Bridger) spokeHandler.updateBridger(poolId, whoAddr, canManage);
            else revert InvalidManagerKind();
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.UpdateManager({poolId: poolId.raw(), kind: uint8(kind), who: who, canManage: canManage})
                    .serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IScheduleAuthMessageSender
    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target, address refund) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            scheduleAuth.scheduleRely(target.toAddress());
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(centrifugeId, MessageLib.ScheduleUpgrade({target: target}).serialize(), false, refund);
        }
    }

    /// @inheritdoc IScheduleAuthMessageSender
    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target, address refund) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            scheduleAuth.cancelRely(target.toAddress());
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(centrifugeId, MessageLib.CancelUpgrade({target: target}).serialize(), false, refund);
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendInitiateTransferShares(
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hubHandler.initiateTransferShares{value: msg.value}(
                localCentrifugeId,
                targetCentrifugeId,
                poolId,
                scId,
                sender,
                receiver,
                amount,
                remoteExtraGasLimit,
                refund
            );
        } else {
            _send(
                poolId.centrifugeId(),
                MessageLib.InitiateTransferShares({
                        centrifugeId: targetCentrifugeId,
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        receiver: receiver,
                        amount: amount,
                        remoteExtraGasLimit: remoteExtraGasLimit,
                        extraGasLimit: extraGasLimit,
                        sender: sender
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendExecuteTransferShares(
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        if (targetCentrifugeId == localCentrifugeId) {
            // Spoke chain X => Hub chain Y => Spoke chain Y
            spokeHandler.executeTransferShares(poolId, scId, receiver, amount);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                targetCentrifugeId,
                MessageLib.ExecuteTransferShares({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        receiver: receiver,
                        amount: amount,
                        extraGasLimit: extraGasLimit
                    }).serialize(),
                originCentrifugeId != localCentrifugeId,
                refund
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        UpdateData calldata data,
        D18 pricePoolPerAsset,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hubHandler.updateHoldingAmount(
                localCentrifugeId,
                poolId,
                scId,
                assetId,
                data.netAmount,
                pricePoolPerAsset,
                data.isIncrease,
                data.isSnapshot,
                data.nonce
            );
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                poolId.centrifugeId(),
                MessageLib.UpdateHoldingAmount({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        assetId: assetId.raw(),
                        amount: data.netAmount,
                        pricePoolPerAsset: pricePoolPerAsset.raw(),
                        timestamp: uint64(block.timestamp),
                        isIncrease: data.isIncrease,
                        isSnapshot: data.isSnapshot,
                        nonce: data.nonce,
                        extraGasLimit: extraGasLimit
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        UpdateData calldata data,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hubHandler.updateShares(
                localCentrifugeId, poolId, scId, data.netAmount, data.isIncrease, data.isSnapshot, data.nonce
            );
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                poolId.centrifugeId(),
                MessageLib.UpdateShares({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        shares: data.netAmount,
                        timestamp: uint64(block.timestamp),
                        isIssuance: data.isIncrease,
                        isSnapshot: data.isSnapshot,
                        nonce: data.nonce,
                        extraGasLimit: extraGasLimit
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals, address refund)
        external
        payable
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            hubHandler.registerAsset(assetId, decimals);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                centrifugeId,
                MessageLib.RegisterAsset({assetId: assetId.raw(), decimals: decimals}).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool unpaidMode,
        address refund
    ) external payable auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hubHandler.request(poolId, scId, assetId, payload);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                poolId.centrifugeId(),
                MessageLib.Request({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        assetId: assetId.raw(),
                        extraGasLimit: extraGasLimit,
                        payload: payload
                    }).serialize(),
                unpaidMode,
                refund
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendManagerSpokeCall(
        PoolId poolId,
        bytes32 target,
        bytes calldata payload,
        bytes32 sender,
        uint128 extraGasLimit,
        address refund
    ) external payable auth {
        uint16 hubCentrifugeId = poolId.centrifugeId();

        if (hubCentrifugeId == localCentrifugeId) {
            envoy.callFromSpoke(poolId, target.toAddress(), payload, localCentrifugeId, sender);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                hubCentrifugeId,
                MessageLib.ManagerCallFromSpoke({
                        poolId: poolId.raw(),
                        target: target,
                        sender: sender,
                        extraGasLimit: extraGasLimit,
                        payload: payload
                    }).serialize(),
                false,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendRequestCallback(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool unpaidMode,
        address refund
    ) external payable auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            spokeHandler.requestCallback(poolId, scId, assetId, payload);
            SafeTransferLib.safeTransferETH(refund, msg.value);
        } else {
            _send(
                assetId.centrifugeId(),
                MessageLib.RequestCallback({
                        poolId: poolId.raw(),
                        scId: scId.raw(),
                        assetId: assetId.raw(),
                        extraGasLimit: extraGasLimit,
                        payload: payload
                    }).serialize(),
                unpaidMode,
                refund
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendSetPoolAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        bytes32[] memory adapters,
        uint8 threshold,
        address refund
    ) external payable auth {
        if (centrifugeId == localCentrifugeId) {
            revert CannotBeSentLocally();
        } else {
            _send(
                centrifugeId,
                MessageLib.SetPoolAdapters({poolId: poolId.raw(), threshold: threshold, adapterList: adapters})
                    .serialize(),
                false,
                refund
            );
        }
    }

    function _send(uint16 centrifugeId, bytes memory message, bool unpaidMode, address refund) internal {
        gateway.send{value: msg.value}(centrifugeId, message, unpaidMode, refund);
    }
}
