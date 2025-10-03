// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageProcessor} from "./interfaces/IMessageProcessor.sol";
import {MessageType, MessageLib, VaultUpdateKind} from "./libraries/MessageLib.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IRecoverable} from "../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IAdapter} from "../core/interfaces/IAdapter.sol";
import {IGateway} from "../core/interfaces/IGateway.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IMultiAdapter} from "../core/interfaces/IMultiAdapter.sol";
import {IMessageHandler} from "../core/interfaces/IMessageHandler.sol";
import {IRequestManager} from "../core/interfaces/IRequestManager.sol";
import {IMessageProperties} from "../core/interfaces/IMessageProperties.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IUpdateContractGatewayHandler,
    IVaultRegistryGatewayHandler,
    IUpdateHubContractGatewayHandler
} from "../core/interfaces/IGatewayHandlers.sol";

import {IRoot} from "../admin/interfaces/IRoot.sol";
import {ITokenRecoverer} from "../admin/interfaces/ITokenRecoverer.sol";

contract MessageProcessor is Auth, IMessageProcessor {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;

    uint16 public constant MAINNET_CENTRIFUGE_ID = 1;

    IRoot public immutable root;
    ITokenRecoverer public immutable tokenRecoverer;

    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    ISpokeGatewayHandler public spoke;
    IHubGatewayHandler public hubHandler;
    IBalanceSheetGatewayHandler public balanceSheet;
    IVaultRegistryGatewayHandler public vaultRegistry;
    IUpdateContractGatewayHandler public contractUpdater;
    IUpdateHubContractGatewayHandler public hubContractUpdater;

    constructor(IRoot root_, ITokenRecoverer tokenRecoverer_, address deployer) Auth(deployer) {
        root = root_;
        tokenRecoverer = tokenRecoverer_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external auth {
        if (what == "hubHandler") hubHandler = IHubGatewayHandler(data);
        else if (what == "spoke") spoke = ISpokeGatewayHandler(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else if (what == "vaultRegistry") vaultRegistry = IVaultRegistryGatewayHandler(data);
        else if (what == "contractUpdater") contractUpdater = IUpdateContractGatewayHandler(data);
        else if (what == "hubContractUpdater") hubContractUpdater = IUpdateHubContractGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Handlers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external auth {
        MessageType kind = message.messageType();
        gateway.setUnpaidMode(true);

        uint16 sourceCentrifugeId = message.messageSourceCentrifugeId();
        require(sourceCentrifugeId == 0 || sourceCentrifugeId == centrifugeId, InvalidSourceChain());

        if (kind == MessageType.ScheduleUpgrade) {
            require(centrifugeId == MAINNET_CENTRIFUGE_ID, OnlyFromMainnet());
            MessageLib.ScheduleUpgrade memory m = message.deserializeScheduleUpgrade();
            root.scheduleRely(m.target.toAddress());
        } else if (kind == MessageType.CancelUpgrade) {
            require(centrifugeId == MAINNET_CENTRIFUGE_ID, OnlyFromMainnet());
            MessageLib.CancelUpgrade memory m = message.deserializeCancelUpgrade();
            root.cancelRely(m.target.toAddress());
        } else if (kind == MessageType.RecoverTokens) {
            require(centrifugeId == MAINNET_CENTRIFUGE_ID, OnlyFromMainnet());
            MessageLib.RecoverTokens memory m = message.deserializeRecoverTokens();
            tokenRecoverer.recoverTokens(
                IRecoverable(m.target.toAddress()), m.token.toAddress(), m.tokenId, m.to.toAddress(), m.amount
            );
        } else if (kind == MessageType.RegisterAsset) {
            MessageLib.RegisterAsset memory m = message.deserializeRegisterAsset();
            hubHandler.registerAsset(AssetId.wrap(m.assetId), m.decimals);
        } else if (kind == MessageType.SetPoolAdapters) {
            MessageLib.SetPoolAdapters memory m = message.deserializeSetPoolAdapters();
            IAdapter[] memory adapters = new IAdapter[](m.adapterList.length);
            for (uint256 i; i < adapters.length; i++) {
                adapters[i] = IAdapter(m.adapterList[i].toAddress());
            }
            multiAdapter.setAdapters(centrifugeId, PoolId.wrap(m.poolId), adapters, m.threshold, m.recoveryIndex);
        } else if (kind == MessageType.Request) {
            MessageLib.Request memory m = MessageLib.deserializeRequest(message);
            hubHandler.request(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload);
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
            hubHandler.initiateTransferShares(
                centrifugeId,
                m.centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                m.receiver,
                m.amount,
                m.extraGasLimit,
                address(0) // Refund is not used because we're in unpaid mode with no payment
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
        } else if (kind == MessageType.UpdateHubContract) {
            MessageLib.UpdateHubContract memory m = MessageLib.deserializeUpdateHubContract(message);
            hubContractUpdater.execute(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.sender.toAddress(), m.target.toAddress(), m.payload
            );
        } else if (kind == MessageType.RequestCallback) {
            MessageLib.RequestCallback memory m = MessageLib.deserializeRequestCallback(message);
            spoke.requestCallback(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.payload);
        } else if (kind == MessageType.UpdateVault) {
            MessageLib.UpdateVault memory m = MessageLib.deserializeUpdateVault(message);
            vaultRegistry.updateVault(
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.vaultOrFactory.toAddress(),
                VaultUpdateKind(m.kind)
            );
        } else if (kind == MessageType.SetRequestManager) {
            MessageLib.SetRequestManager memory m = MessageLib.deserializeSetRequestManager(message);
            spoke.setRequestManager(PoolId.wrap(m.poolId), IRequestManager(m.manager.toAddress()));
        } else if (kind == MessageType.UpdateBalanceSheetManager) {
            MessageLib.UpdateBalanceSheetManager memory m = MessageLib.deserializeUpdateBalanceSheetManager(message);
            balanceSheet.updateManager(PoolId.wrap(m.poolId), m.who.toAddress(), m.canManage);
        } else if (kind == MessageType.UpdateHoldingAmount) {
            MessageLib.UpdateHoldingAmount memory m = message.deserializeUpdateHoldingAmount();
            hubHandler.updateHoldingAmount(
                centrifugeId,
                PoolId.wrap(m.poolId),
                ShareClassId.wrap(m.scId),
                AssetId.wrap(m.assetId),
                m.amount,
                D18.wrap(m.pricePoolPerAsset),
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
        } else if (kind == MessageType.MaxAssetPriceAge) {
            MessageLib.MaxAssetPriceAge memory m = message.deserializeMaxAssetPriceAge();
            spoke.setMaxAssetPriceAge(
                PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), AssetId.wrap(m.assetId), m.maxPriceAge
            );
        } else if (kind == MessageType.MaxSharePriceAge) {
            MessageLib.MaxSharePriceAge memory m = message.deserializeMaxSharePriceAge();
            spoke.setMaxSharePriceAge(PoolId.wrap(m.poolId), ShareClassId.wrap(m.scId), m.maxPriceAge);
        } else if (kind == MessageType.UpdateGatewayManager) {
            MessageLib.UpdateGatewayManager memory m = message.deserializeUpdateGatewayManager();
            gateway.updateManager(PoolId.wrap(m.poolId), m.who.toAddress(), m.canManage);
        } else {
            revert InvalidMessage(uint8(kind));
        }

        gateway.setUnpaidMode(false);
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
