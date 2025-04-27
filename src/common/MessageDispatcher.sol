// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
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
    using MathLib for uint256;

    IRoot public immutable root;
    IGateway public immutable gateway;
    ITokenRecoverer public immutable tokenRecoverer;

    uint16 public immutable localCentrifugeId;

    IHubGatewayHandler public hub;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetGatewayHandler public balanceSheet;

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

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageDispatcher
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHubGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IMessageDispatcher
    function estimate(uint16 centrifugeId, bytes calldata payload) external view returns (uint256 amount) {
        if (centrifugeId == localCentrifugeId) return 0;
        return gateway.estimate(centrifugeId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.addPool(poolId);
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
            poolManager.addShareClass(poolId, scId, name, symbol, decimals, salt, hook.toAddress());
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
    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol
    ) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.updateShareMetadata(poolId, scId, name, symbol);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.NotifyShareMetadata({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    name: name,
                    symbol: symbol.toBytes32()
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateShareHook(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 hook) external auth {
        if (centrifugeId == localCentrifugeId) {
            poolManager.updateShareHook(poolId, scId, hook.toAddress());
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.UpdateShareHook({poolId: poolId.raw(), scId: scId.raw(), hook: hook}).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPricePoolPerShare(uint16 chainId, PoolId poolId, ShareClassId scId, D18 sharePrice)
        external
        auth
    {
        uint64 timestamp = block.timestamp.toUint64();
        if (chainId == localCentrifugeId) {
            poolManager.updatePricePoolPerShare(poolId, scId, sharePrice.raw(), timestamp);
        } else {
            gateway.send(
                chainId,
                MessageLib.NotifyPricePoolPerShare({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    price: sharePrice.raw(),
                    timestamp: timestamp
                }).serialize()
            );
        }
    }

    function sendNotifyPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price) external auth {
        uint64 timestamp = block.timestamp.toUint64();
        if (assetId.centrifugeId() == localCentrifugeId) {
            poolManager.updatePricePoolPerAsset(poolId, scId, assetId, price.raw(), timestamp);
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.NotifyPricePoolPerAsset({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    price: price.raw(),
                    timestamp: timestamp
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
                poolId, scId, investor.toAddress(), assetId, assetAmount, shareAmount
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
                poolId, scId, investor.toAddress(), assetId, assetAmount, shareAmount
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
                poolId, scId, investor.toAddress(), assetId, cancelledAmount, cancelledAmount
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
            investmentManager.fulfillCancelRedeemRequest(poolId, scId, investor.toAddress(), assetId, cancelledShares);
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
            poolManager.updateRestriction(poolId, scId, payload);
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
            poolManager.updateContract(poolId, scId, target.toAddress(), payload);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendApprovedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.approvedDeposits(poolId, scId, assetId, assetAmount, pricePoolPerAsset);
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.ApprovedDeposits({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    assetAmount: assetAmount,
                    pricePoolPerAsset: pricePoolPerAsset.raw()
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendIssuedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.issuedShares(poolId, scId, shareAmount, pricePoolPerShare);
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.IssuedShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    shareAmount: shareAmount,
                    pricePoolPerShare: pricePoolPerShare.raw()
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendRevokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            investmentManager.revokedShares(poolId, scId, assetId, assetAmount, shareAmount, pricePoolPerShare);
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.RevokedShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    assetAmount: assetAmount,
                    shareAmount: shareAmount,
                    pricePoolPerShare: pricePoolPerShare.raw()
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendTriggerIssueShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, address who, uint128 shares)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            balanceSheet.triggerIssueShares(poolId, scId, who, shares);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.TriggerIssueShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    who: who.toBytes32(),
                    shares: shares
                }).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendTriggerSubmitQueuedShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId) external auth {
        if (centrifugeId == localCentrifugeId) {
            balanceSheet.submitQueuedShares(poolId, scId);
        } else {
            gateway.send(
                centrifugeId, MessageLib.TriggerSubmitQueuedShares({poolId: poolId.raw(), scId: scId.raw()}).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendTriggerSubmitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external auth {
        if (assetId.centrifugeId() == localCentrifugeId) {
            balanceSheet.submitQueuedAssets(poolId, scId, assetId);
        } else {
            gateway.send(
                assetId.centrifugeId(),
                MessageLib.TriggerSubmitQueuedAssets({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw()})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendSetQueue(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bool enabled) external auth {
        if (centrifugeId == localCentrifugeId) {
            balanceSheet.setQueue(poolId, scId, enabled);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.SetQueue({poolId: poolId.raw(), scId: scId.raw(), enabled: enabled}).serialize()
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
    function sendInitiateRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            gateway.initiateRecovery(adapterCentrifugeId, IAdapter(adapter.toAddress()), hash);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.InitiateRecovery({hash: hash, adapter: adapter, centrifugeId: adapterCentrifugeId}).serialize(
                )
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendDisputeRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            gateway.disputeRecovery(adapterCentrifugeId, IAdapter(adapter.toAddress()), hash);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.DisputeRecovery({hash: hash, adapter: adapter, centrifugeId: adapterCentrifugeId}).serialize(
                )
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount)
        external
        auth
    {
        if (centrifugeId == localCentrifugeId) {
            poolManager.handleTransferShares(poolId, scId, receiver.toAddress(), amount);
        } else {
            gateway.send(
                centrifugeId,
                MessageLib.TransferShares({poolId: poolId.raw(), scId: scId.raw(), receiver: receiver, amount: amount})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.depositRequest(poolId, scId, investor, assetId, amount);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.DepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.redeemRequest(poolId, scId, investor, assetId, amount);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.RedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    amount: amount
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.cancelDepositRequest(poolId, scId, investor, assetId);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.CancelDepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw()
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId)
        external
        auth
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.cancelRedeemRequest(poolId, scId, investor, assetId);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.CancelRedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw()
                }).serialize()
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
        D18 pricePoolPerAsset,
        bool isIncrease
    ) external auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateHoldingAmount(poolId, scId, assetId, amount, pricePoolPerAsset, isIncrease);
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateHoldingAmount({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    who: provider.toBytes32(),
                    amount: amount,
                    pricePerUnit: pricePoolPerAsset.raw(),
                    timestamp: uint64(block.timestamp),
                    isIncrease: isIncrease
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateShares(PoolId poolId, ShareClassId scId, uint128 shares, bool isIssuance) external auth {
        if (poolId.centrifugeId() == localCentrifugeId) {
            if (isIssuance) {
                hub.increaseShareIssuance(poolId, scId, shares);
            } else {
                hub.decreaseShareIssuance(poolId, scId, shares);
            }
        } else {
            gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    shares: shares,
                    timestamp: uint64(block.timestamp),
                    isIssuance: isIssuance
                }).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals) external auth {
        if (centrifugeId == localCentrifugeId) {
            hub.registerAsset(assetId, decimals);
        } else {
            gateway.send(
                centrifugeId, MessageLib.RegisterAsset({assetId: assetId.raw(), decimals: decimals}).serialize()
            );
        }
    }
}
