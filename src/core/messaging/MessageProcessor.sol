// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAdapter} from "./interfaces/IAdapter.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IScheduleAuth} from "./interfaces/IScheduleAuth.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";
import {ISpokeGatewayHandler, IHubGatewayHandler} from "./interfaces/IGatewayHandlers.sol";
import {MessageType, MessageLib, VaultUpdateKind, ManagerKind} from "./libraries/MessageLib.sol";

import {Auth} from "../../misc/Auth.sol";
import {D18} from "../../misc/types/D18.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {IEnvoy} from "../utils/interfaces/IEnvoy.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IPolicy} from "../utils/interfaces/IPolicy.sol";
import {IRegistrar} from "../spoke/interfaces/IRegistrar.sol";
import {ISpokeRequestManager} from "../spoke/interfaces/ISpokeRequestManager.sol";

/// @title  MessageProcessor
/// @notice This contract deserializes and processes incoming cross-chain messages, routing them to appropriate
///         handlers based on message type, validating source chains for privileged operations, and managing
///         unpaid mode for internal protocol message processing.
contract MessageProcessor is Auth, IMessageProcessor {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;

    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    ISpokeGatewayHandler public spokeHandler;
    IHubGatewayHandler public hubHandler;
    IScheduleAuth public immutable scheduleAuth;
    IEnvoy public envoy;

    constructor(IScheduleAuth scheduleAuth_, address deployer) Auth(deployer) {
        scheduleAuth = scheduleAuth_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external auth {
        if (what == "hubHandler") hubHandler = IHubGatewayHandler(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "spokeHandler") spokeHandler = ISpokeGatewayHandler(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else if (what == "envoy") envoy = IEnvoy(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (_handleHub(centrifugeId, kind, message)) return;
        if (_handleSpoke(centrifugeId, kind, message)) return;
        if (_handleRoot(kind, message)) return;

        revert InvalidMessage(uint8(kind));
    }

    /// @dev Messages processed on the hub side.
    function _handleHub(uint16 centrifugeId, MessageType kind, bytes calldata message) internal returns (bool) {
        if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            hubHandler.registerAsset(AssetId.wrap(m.assetId), m.decimals);
        } else if (kind == MessageType.Request) {
            MessageLib.Request memory m = MessageLib.deserializeRequest(message);
            hubHandler.request(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload);
        } else if (kind == MessageType.InitiateTransferShares) {
            MessageLib.InitiateTransferShares memory m = MessageLib.deserializeInitiateTransferShares(message);
            hubHandler.initiateTransferShares(
                centrifugeId,
                m.centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.sender,
                m.receiver,
                m.amount,
                m.remoteExtraGasLimit,
                address(0) // Refund is not used because we're in unpaid mode with no payment
            );
        } else if (kind == MessageType.UpdateAssets) {
            MessageLib.UpdateAssets memory m = message.deserializeUpdateAssets();
            hubHandler.updateAssets(
                centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                m.isIncrease,
                m.isSnapshot,
                m.nonce
            );
        } else if (kind == MessageType.UpdateShares) {
            MessageLib.UpdateShares memory m = message.deserializeUpdateShares();
            hubHandler.updateShares(
                centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.shares,
                m.isIssuance,
                m.isSnapshot,
                m.nonce
            );
        } else if (kind == MessageType.ManagerCallFromSpoke) {
            MessageLib.ManagerCallFromSpoke memory m = MessageLib.deserializeManagerCallFromSpoke(message);
            envoy.callFromSpoke(PoolId.wrap(m.poolId), m.target.toAddress(), m.payload, centrifugeId, m.sender);
        } else {
            return false;
        }
        return true;
    }

    /// @dev Messages processed on the spoke side.
    function _handleSpoke(uint16 centrifugeId, MessageType kind, bytes calldata message) internal returns (bool) {
        if (kind == MessageType.NotifyPool) {
            MessageLib.NotifyPool memory m = MessageLib.deserializeNotifyPool(message);
            spokeHandler.addPool(PoolId.wrap(m.poolId));
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            spokeHandler.addShareClass(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.name,
                m.symbol.toString(),
                m.decimals,
                m.salt,
                IRegistrar(m.registrar.toAddress()),
                m.payload
            );
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            MessageLib.NotifyPricePoolPerShare memory m = MessageLib.deserializeNotifyPricePoolPerShare(message);
            spokeHandler.updatePricePoolPerShare(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), D18.wrap(m.price), m.timestamp
            );
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            MessageLib.NotifyPricePoolPerAsset memory m = MessageLib.deserializeNotifyPricePoolPerAsset(message);
            spokeHandler.updatePricePoolPerAsset(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                D18.wrap(m.price),
                m.timestamp
            );
        } else if (kind == MessageType.NotifyShareMetadata) {
            MessageLib.NotifyShareMetadata memory m = MessageLib.deserializeNotifyShareMetadata(message);
            spokeHandler.updateShareMetadata(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.name, m.symbol.toString()
            );
        } else if (kind == MessageType.ExecuteTransferShares) {
            MessageLib.ExecuteTransferShares memory m = MessageLib.deserializeExecuteTransferShares(message);
            spokeHandler.executeTransferShares(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.receiver, m.amount);
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            spokeHandler.updateRestriction(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.payload);
        } else if (kind == MessageType.RequestCallback) {
            MessageLib.RequestCallback memory m = MessageLib.deserializeRequestCallback(message);
            spokeHandler.requestCallback(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload
            );
        } else if (kind == MessageType.UpdateVault) {
            MessageLib.UpdateVault memory m = MessageLib.deserializeUpdateVault(message);
            spokeHandler.updateVault(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.vaultOrFactory.toAddress(),
                VaultUpdateKind(m.kind),
                m.payload
            );
        } else if (kind == MessageType.SetRequestManager) {
            MessageLib.SetRequestManager memory m = MessageLib.deserializeSetRequestManager(message);
            spokeHandler.setRequestManager(PoolId.wrap(m.poolId), ISpokeRequestManager(m.manager.toAddress()));
        } else if (kind == MessageType.SetPoolAdapters) {
            MessageLib.SetPoolAdapters memory m = message.deserializeSetPoolAdapters();
            PoolId poolId = PoolId.wrap(m.poolId);
            IAdapter[] memory adapters = new IAdapter[](m.adapterList.length);
            for (uint256 i; i < adapters.length; i++) {
                adapters[i] = IAdapter(m.adapterList[i].toAddress());
            }
            multiAdapter.setAdapters(centrifugeId, poolId, adapters, m.threshold, m.targetSessionId);
        } else if (kind == MessageType.ManagerCallFromHub) {
            MessageLib.ManagerCallFromHub memory m = MessageLib.deserializeManagerCallFromHub(message);
            envoy.callFromHub(PoolId.wrap(m.poolId), m.target.toAddress(), m.payload);
        } else if (kind == MessageType.SetPolicy) {
            MessageLib.SetPolicy memory m = MessageLib.deserializeSetPolicy(message);
            spokeHandler.setPolicy(PoolId.wrap(m.poolId), IPolicy(m.policy.toAddress()));
        } else if (kind == MessageType.AuthorizeSpokeCall) {
            MessageLib.AuthorizeSpokeCall memory m = MessageLib.deserializeAuthorizeSpokeCall(message);
            spokeHandler.authorize(PoolId.wrap(m.poolId), m.payload);
        } else if (kind == MessageType.UnauthorizeSpokeCall) {
            MessageLib.UnauthorizeSpokeCall memory m = MessageLib.deserializeUnauthorizeSpokeCall(message);
            spokeHandler.unauthorize(PoolId.wrap(m.poolId), m.payload);
        } else if (kind == MessageType.UpdateManager) {
            MessageLib.UpdateManager memory m = MessageLib.deserializeUpdateManager(message);
            PoolId poolId = PoolId.wrap(m.poolId);
            address who = m.who.toAddress();
            ManagerKind managerKind = ManagerKind(m.kind);
            if (managerKind == ManagerKind.Spoke) {
                spokeHandler.updateManager(poolId, who, m.canManage);
            } else if (managerKind == ManagerKind.Adapter) {
                multiAdapter.updateManager(poolId, who, m.canManage);
            } else if (managerKind == ManagerKind.Gateway) {
                gateway.updateManager(poolId, who, m.canManage);
            } else if (managerKind == ManagerKind.Bridger) {
                spokeHandler.updateBridger(poolId, who, m.canManage);
            } else {
                revert InvalidManagerKind(); // Unreachable due the enum check
            }
        } else {
            return false;
        }
        return true;
    }

    /// @dev Root-level upgrade scheduling.
    function _handleRoot(MessageType kind, bytes calldata message) internal returns (bool) {
        if (kind == MessageType.ScheduleUpgrade) {
            MessageLib.ScheduleUpgrade memory m = message.deserializeScheduleUpgrade();
            scheduleAuth.scheduleRely(m.target.toAddress());
        } else if (kind == MessageType.CancelUpgrade) {
            MessageLib.CancelUpgrade memory m = message.deserializeCancelUpgrade();
            scheduleAuth.cancelRely(m.target.toAddress());
        } else {
            return false;
        }
        return true;
    }
}
