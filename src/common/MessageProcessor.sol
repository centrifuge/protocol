// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {ShareClassId} from "./types/ShareClassId.sol";
import {IMessageHandler} from "./interfaces/IMessageHandler.sol";
import {IRequestManager} from "./interfaces/IRequestManager.sol";
import {ITokenRecoverer} from "./interfaces/ITokenRecoverer.sol";
import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";
import {IMessageProperties} from "./interfaces/IMessageProperties.sol";
import {MessageType, MessageLib, VaultUpdateKind} from "./libraries/MessageLib.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IUpdateContractGatewayHandler
} from "./interfaces/IGatewayHandlers.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IRecoverable} from "../misc/interfaces/IRecoverable.sol";

contract MessageProcessor is Auth, IMessageProcessor {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;

    IRoot public immutable root;
    ITokenRecoverer public immutable tokenRecoverer;

    IHubGatewayHandler public hub;
    ISpokeGatewayHandler public spoke;
    IBalanceSheetGatewayHandler public balanceSheet;
    IUpdateContractGatewayHandler public contractUpdater;

    constructor(IRoot root_, ITokenRecoverer tokenRecoverer_, address deployer) Auth(deployer) {
        root = root_;
        tokenRecoverer = tokenRecoverer_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "spoke") spoke = ISpokeGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else if (what == "contractUpdater") contractUpdater = IUpdateContractGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external auth {
        MessageType kind = message.messageType();
        uint16 sourceCentrifugeId = message.messageSourceCentrifugeId();

        require(sourceCentrifugeId == 0 || sourceCentrifugeId == centrifugeId, InvalidSourceChain());

        if (kind == MessageType.ScheduleUpgrade) {
            MessageLib.ScheduleUpgrade memory m = message.deserializeScheduleUpgrade();
            root.scheduleRely(m.target.toAddress());
        } else if (kind == MessageType.CancelUpgrade) {
            MessageLib.CancelUpgrade memory m = message.deserializeCancelUpgrade();
            root.cancelRely(m.target.toAddress());
        } else if (kind == MessageType.RecoverTokens) {
            MessageLib.RecoverTokens memory m = message.deserializeRecoverTokens();
            tokenRecoverer.recoverTokens(
                IRecoverable(m.target.toAddress()), m.token.toAddress(), m.tokenId, m.to.toAddress(), m.amount
            );
        } else if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            hub.registerAsset(AssetId.wrap(m.assetId), m.decimals);
        } else if (kind == MessageType.Request) {
            MessageLib.Request memory m = MessageLib.deserializeRequest(message);
            hub.request(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload);
        } else if (kind == MessageType.NotifyPool) {
            spoke.addPool(PoolId.wrap(MessageLib.deserializeNotifyPool(message).poolId));
        } else if (kind == MessageType.NotifyShareClass) {
            MessageLib.NotifyShareClass memory m = MessageLib.deserializeNotifyShareClass(message);
            spoke.addShareClass(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.name,
                m.symbol.toString(),
                m.decimals,
                m.salt,
                m.hook.toAddress()
            );
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            MessageLib.NotifyPricePoolPerShare memory m = MessageLib.deserializeNotifyPricePoolPerShare(message);
            spoke.updatePricePoolPerShare(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), D18.wrap(m.price), m.timestamp
            );
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            MessageLib.NotifyPricePoolPerAsset memory m = MessageLib.deserializeNotifyPricePoolPerAsset(message);
            spoke.updatePricePoolPerAsset(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                D18.wrap(m.price),
                m.timestamp
            );
        } else if (kind == MessageType.NotifyShareMetadata) {
            MessageLib.NotifyShareMetadata memory m = MessageLib.deserializeNotifyShareMetadata(message);
            spoke.updateShareMetadata(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.name, m.symbol.toString());
        } else if (kind == MessageType.UpdateShareHook) {
            MessageLib.UpdateShareHook memory m = MessageLib.deserializeUpdateShareHook(message);
            spoke.updateShareHook(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.hook.toAddress());
        } else if (kind == MessageType.InitiateTransferShares) {
            MessageLib.InitiateTransferShares memory m = MessageLib.deserializeInitiateTransferShares(message);
            hub.initiateTransferShares(
                m.centrifugeId, PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.receiver, m.amount, m.extraGasLimit
            );
        } else if (kind == MessageType.ExecuteTransferShares) {
            MessageLib.ExecuteTransferShares memory m = MessageLib.deserializeExecuteTransferShares(message);
            spoke.executeTransferShares(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.receiver, m.amount);
        } else if (kind == MessageType.UpdateRestriction) {
            MessageLib.UpdateRestriction memory m = MessageLib.deserializeUpdateRestriction(message);
            spoke.updateRestriction(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.payload);
        } else if (kind == MessageType.UpdateContract) {
            MessageLib.UpdateContract memory m = MessageLib.deserializeUpdateContract(message);
            contractUpdater.execute(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.target.toAddress(), m.payload);
        } else if (kind == MessageType.RequestCallback) {
            MessageLib.RequestCallback memory m = MessageLib.deserializeRequestCallback(message);
            spoke.requestCallback(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload);
        } else if (kind == MessageType.UpdateVault) {
            MessageLib.UpdateVault memory m = MessageLib.deserializeUpdateVault(message);
            spoke.updateVault(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.vaultOrFactory.toAddress(),
                VaultUpdateKind(m.kind)
            );
        } else if (kind == MessageType.SetRequestManager) {
            MessageLib.SetRequestManager memory m = MessageLib.deserializeSetRequestManager(message);
            spoke.setRequestManager(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                IRequestManager(m.manager.toAddress())
            );
        } else if (kind == MessageType.UpdateBalanceSheetManager) {
            MessageLib.UpdateBalanceSheetManager memory m = MessageLib.deserializeUpdateBalanceSheetManager(message);
            balanceSheet.updateManager(PoolId.wrap(m.poolId), m.who.toAddress(), m.canManage);
        } else if (kind == MessageType.UpdateHoldingAmount) {
            MessageLib.UpdateHoldingAmount memory m = message.deserializeUpdateHoldingAmount();
            hub.updateHoldingAmount(
                centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                D18.wrap(m.pricePerUnit),
                m.isIncrease,
                m.isSnapshot,
                m.nonce
            );
        } else if (kind == MessageType.UpdateShares) {
            MessageLib.UpdateShares memory m = message.deserializeUpdateShares();
            hub.updateShares(
                centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.shares,
                m.isIssuance,
                m.isSnapshot,
                m.nonce
            );
        } else if (kind == MessageType.MaxAssetPriceAge) {
            MessageLib.MaxAssetPriceAge memory m = message.deserializeMaxAssetPriceAge();
            spoke.setMaxAssetPriceAge(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.maxPriceAge
            );
        } else if (kind == MessageType.MaxSharePriceAge) {
            MessageLib.MaxSharePriceAge memory m = message.deserializeMaxSharePriceAge();
            spoke.setMaxSharePriceAge(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.maxPriceAge);
        } else {
            revert InvalidMessage(uint8(kind));
        }
    }

    /// @inheritdoc IMessageProperties
    function messageLength(bytes calldata message) external pure returns (uint16) {
        return message.messageLength();
    }

    /// @inheritdoc IMessageProperties
    function messagePoolId(bytes calldata message) external pure returns (PoolId) {
        return message.messagePoolId();
    }
}
