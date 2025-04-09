// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {JournalEntry, Meta} from "src/common/libraries/JournalEntryLib.sol";
import {
    IInvestmentManagerGatewayHandler,
    IPoolManagerGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler
} from "src/common/interfaces/IGatewayHandlers.sol";
import {IVaultMessageSender, IPoolMessageSender, IRootMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {IMessageDispatcher} from "src/common/interfaces/IMessageDispatcher.sol";
import {ITokenRecoverer} from "src/common/interfaces/ITokenRecoverer.sol";

contract MessageDispatcher is Auth, IMessageDispatcher {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;

    IRoot public immutable root;
    IGateway public immutable gateway;
    ITokenRecoverer public immutable tokenRecoverer;

    IHubGatewayHandler public hub;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetGatewayHandler public balanceSheet;

    uint16 public localCentrifugeId;

    constructor(
        uint16 localCentrifugeId_,
        IRoot root_,
        IGateway gateway_,
        ITokenRecoverer tokenRecoverer_,
        address deployer
    ) Auth(deployer) {
        localCentrifugeId = localCentrifugeId_;
        root = root_;
        gateway = gateway_;
        tokenRecoverer = tokenRecoverer_;
    }

    /// @inheritdoc IMessageDispatcher
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    /// @inheritdoc IMessageDispatcher
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256 amount) {
        if (centrifugeId == localCentrifugeId) return 0;
        (, amount) = IGateway(gateway).estimate(centrifugeId, payload);
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.addPool(poolId.raw());
        } else {
            gateway.send(centrifugeId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyShareClass(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.addShareClass(poolId.raw(), scId.raw(), name, symbol, decimals, salt, hook.toAddress());
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.NotifyShareClass({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    name: name,
                    symbol: symbol.toBytes32(),
                    decimals: decimals,
                    salt: salt,
                    hook: hook
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.fulfillDepositRequest(
                poolId.raw(), scId.raw(), investor.toAddress(), assetId.raw(), assetAmount, shareAmount
            );
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.FulfilledDepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    assetAmount: assetAmount,
                    shareAmount: shareAmount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.fulfillRedeemRequest(
                poolId.raw(), scId.raw(), investor.toAddress(), assetId.raw(), assetAmount, shareAmount
            );
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.FulfilledRedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    assetAmount: assetAmount,
                    shareAmount: shareAmount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.fulfillCancelDepositRequest(
                poolId.raw(), scId.raw(), investor.toAddress(), assetId.raw(), cancelledAmount, cancelledAmount
            );
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.FulfilledCancelDepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    cancelledAmount: cancelledAmount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.fulfillCancelRedeemRequest(
                poolId.raw(), scId.raw(), investor.toAddress(), assetId.raw(), cancelledShares
            );
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.FulfilledCancelRedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    cancelledShares: cancelledShares
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateRestriction(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes calldata payload)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            poolManager.updateRestriction(poolId.raw(), scId.raw(), payload);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.UpdateRestriction({poolId: poolId.raw(), scId: scId.raw(), payload: payload}).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateContract(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.updateContract(poolId.raw(), scId.raw(), target.toAddress(), payload);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target) external auth {
        if (centrifugeId == localCentrifugeId) {
            root.scheduleRely(target.toAddress());
        } else {
            gateway.send(centrifugeId, MessageLib.ScheduleUpgrade({target: target}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target) external auth {
        if (centrifugeId == localCentrifugeId) {
            root.cancelRely(target.toAddress());
        } else {
            gateway.send(centrifugeId, MessageLib.CancelUpgrade({target: target}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendRecoverTokens(
        uint16 centrifugeId,
        bytes32 target,
        bytes32 token,
        uint256 tokenId,
        bytes32 to,
        uint256 amount
    ) external auth {
        if (centrifugeId == localCentrifugeId) {
            tokenRecoverer.recoverTokens(
                IRecoverable(target.toAddress()), token.toAddress(), tokenId, to.toAddress(), amount
            );
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.RecoverTokens({target: target, token: token, tokenId: tokenId, to: to, amount: amount})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendInitiateMessageRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            gateway.initiateMessageRecovery(adapterCentrifugeId, IAdapter(adapter.toAddress()), hash);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.InitiateMessageRecovery({hash: hash, adapter: adapter, centrifugeId: adapterCentrifugeId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendDisputeMessageRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            gateway.disputeMessageRecovery(adapterCentrifugeId, IAdapter(adapter.toAddress()), hash);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.DisputeMessageRecovery({hash: hash, adapter: adapter, centrifugeId: adapterCentrifugeId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 centrifugeId, uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            poolManager.handleTransferShares(poolId, scId, receiver.toAddress(), amount);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.TransferShares({poolId: poolId, scId: scId, receiver: receiver, amount: amount}).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).centrifugeId() == localCentrifugeId) {
            hub.depositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
        } else {
            gateway.send(
                PoolId.wrap(poolId).centrifugeId(),
                MessageLib.DepositRequest({
                    poolId: poolId,
                    scId: scId,
                    investor: investor,
                    assetId: assetId,
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).centrifugeId() == localCentrifugeId) {
            hub.redeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
        } else {
            gateway.send(
                PoolId.wrap(poolId).centrifugeId(),
                MessageLib.RedeemRequest({
                    poolId: poolId,
                    scId: scId,
                    investor: investor,
                    assetId: assetId,
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        if (PoolId.wrap(poolId).centrifugeId() == localCentrifugeId) {
            hub.cancelDepositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
        } else {
            gateway.send(
                PoolId.wrap(poolId).centrifugeId(),
                MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        if (PoolId.wrap(poolId).centrifugeId() == localCentrifugeId) {
            hub.cancelRedeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
        } else {
            gateway.send(
                PoolId.wrap(poolId).centrifugeId(),
                MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        bool isIncrease,
        Meta calldata meta
    ) external auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateHoldingAmount(poolId, scId, assetId, amount, pricePerUnit, isIncrease, meta.debits, meta.credits);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateHoldingAmount({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    who: provider.toBytes32(),
                    amount: amount,
                    pricePerUnit: pricePerUnit.raw(),
                    timestamp: uint64(block.timestamp),
                    isIncrease: isIncrease,
                    debits: meta.debits,
                    credits: meta.credits
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePerUnit)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateHoldingValue(poolId, scId, assetId, pricePerUnit);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateHoldingValue({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    pricePerUnit: pricePerUnit.raw(),
                    timestamp: uint64(block.timestamp)
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        address receiver,
        D18 pricePerShare,
        uint128 shares,
        bool isIssuance
    ) external auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            if (isIssuance) {
                hub.increaseShareIssuance(poolId, scId, pricePerShare, shares);
            } else {
                hub.decreaseShareIssuance(poolId, scId, pricePerShare, shares);
            }
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    who: receiver.toBytes32(),
                    pricePerShare: pricePerShare.raw(),
                    shares: shares,
                    timestamp: uint64(block.timestamp),
                    isIssuance: isIssuance
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendJournalEntry(PoolId poolId, JournalEntry[] calldata debits, JournalEntry[] calldata credits)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateJournal(poolId, debits, credits);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateJournal({poolId: poolId.raw(), debits: debits, credits: credits}).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(uint16 centrifugeId, uint128 assetId, uint8 decimals) external auth {
        if (centrifugeId == localCentrifugeId) {
            hub.registerAsset(AssetId.wrap(assetId), decimals);
        } else {
            gateway.send(centrifugeId, MessageLib.RegisterAsset({assetId: assetId, decimals: decimals}).serialize());
        }
    }
}
