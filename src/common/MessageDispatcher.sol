// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

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

interface IMessageDispatcher is IRootMessageSender, IVaultMessageSender, IPoolMessageSender {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'poolRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}

contract MessageDispatcher is Auth, IMessageDispatcher {
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for *;

    IRoot public immutable root;
    IGateway public immutable gateway;

    IHubGatewayHandler public hub;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetGatewayHandler public balanceSheet;

    uint16 public localCentrifugeId;

    constructor(uint16 centrifugeChainId_, IRoot root_, IGateway gateway_, address deployer) Auth(deployer) {
        localCentrifugeId = centrifugeChainId_;
        root = root_;
        gateway = gateway_;
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

    /// @inheritdoc IPoolMessageSender
    function sendNotifyPool(uint16 chainId, PoolId poolId) external auth {
        if (chainId == localCentrifugeId) {
            poolManager.addPool(poolId.raw());
        } else {
            gateway.send(chainId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendNotifyShareClass(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external auth {
        if (chainId == localCentrifugeId) {
            poolManager.addShareClass(poolId.raw(), scId.raw(), name, symbol, decimals, salt, address(bytes20(hook)));
        } else {
            gateway.send(
                chainId,
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
        if (assetId.chainId() == localCentrifugeId) {
            investmentManager.fulfillDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
            );
        } else {
            gateway.send(
                assetId.chainId(),
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
        if (assetId.chainId() == localCentrifugeId) {
            investmentManager.fulfillRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), assetAmount, shareAmount
            );
        } else {
            gateway.send(
                assetId.chainId(),
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
        if (assetId.chainId() == localCentrifugeId) {
            investmentManager.fulfillCancelDepositRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledAmount, cancelledAmount
            );
        } else {
            gateway.send(
                assetId.chainId(),
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
        if (assetId.chainId() == localCentrifugeId) {
            investmentManager.fulfillCancelRedeemRequest(
                poolId.raw(), scId.raw(), address(bytes20(investor)), assetId.raw(), cancelledShares
            );
        } else {
            gateway.send(
                assetId.chainId(),
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
    function sendUpdateRestriction(uint16 chainId, PoolId poolId, ShareClassId scId, bytes calldata payload)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            poolManager.updateRestriction(poolId.raw(), scId.raw(), payload);
        } else {
            gateway.send(
                chainId,
                MessageLib.UpdateRestriction({poolId: poolId.raw(), scId: scId.raw(), payload: payload}).serialize()
            );
        }
    }

    /// @inheritdoc IPoolMessageSender
    function sendUpdateContract(
        uint16 chainId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external auth {
        if (chainId == localCentrifugeId) {
            poolManager.updateContract(poolId.raw(), scId.raw(), address(bytes20(target)), payload);
        } else {
            gateway.send(
                chainId,
                MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendScheduleUpgrade(uint16 chainId, bytes32 target) external auth {
        if (chainId == localCentrifugeId) {
            root.scheduleRely(address(bytes20(target)));
        } else {
            gateway.send(chainId, MessageLib.ScheduleUpgrade({target: target}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendCancelUpgrade(uint16 chainId, bytes32 target) external auth {
        if (chainId == localCentrifugeId) {
            root.cancelRely(address(bytes20(target)));
        } else {
            gateway.send(chainId, MessageLib.CancelUpgrade({target: target}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendInitiateMessageRecovery(uint16 chainId, uint16 adapterChainId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            gateway.initiateMessageRecovery(adapterChainId, IAdapter(address(bytes20(adapter))), hash);
        } else {
            gateway.send(
                chainId,
                MessageLib.InitiateMessageRecovery({hash: hash, adapter: adapter, domainId: adapterChainId}).serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendDisputeMessageRecovery(uint16 chainId, uint16 adapterChainId, bytes32 adapter, bytes32 hash)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            gateway.disputeMessageRecovery(adapterChainId, IAdapter(address(bytes20(adapter))), hash);
        } else {
            gateway.send(
                chainId,
                MessageLib.DisputeMessageRecovery({hash: hash, adapter: adapter, domainId: adapterChainId}).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 chainId, uint64 poolId, bytes16 scId, bytes32 receiver, uint128 amount)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            poolManager.handleTransferShares(poolId, scId, address(bytes20(receiver)), amount);
        } else {
            gateway.send(
                chainId,
                MessageLib.TransferShares({poolId: poolId, scId: scId, receiver: receiver, amount: amount}).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).chainId() == localCentrifugeId) {
            hub.depositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
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
        if (PoolId.wrap(poolId).chainId() == localCentrifugeId) {
            hub.redeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount);
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
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
        if (PoolId.wrap(poolId).chainId() == localCentrifugeId) {
            hub.cancelDepositRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.CancelDepositRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external auth {
        if (PoolId.wrap(poolId).chainId() == localCentrifugeId) {
            hub.cancelRedeemRequest(PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId));
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
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
        if (poolId.chainId() == localCentrifugeId) {
            hub.updateHoldingAmount(poolId, scId, assetId, amount, pricePerUnit, isIncrease, meta.debits, meta.credits);
        } else {
            gateway.send(
                poolId.chainId(),
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
        if (poolId.chainId() == localCentrifugeId) {
            hub.updateHoldingValue(poolId, scId, assetId, pricePerUnit);
        } else {
            gateway.send(
                poolId.chainId(),
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
        if (poolId.chainId() == localCentrifugeId) {
            if (isIssuance) {
                hub.increaseShareIssuance(poolId, scId, pricePerShare, shares);
            } else {
                hub.decreaseShareIssuance(poolId, scId, pricePerShare, shares);
            }
        } else {
            gateway.send(
                poolId.chainId(),
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
        if (poolId.chainId() == localCentrifugeId) {
            hub.updateJournal(poolId, debits, credits);
        } else {
            gateway.send(
                poolId.chainId(),
                MessageLib.UpdateJournal({poolId: poolId.raw(), debits: debits, credits: credits}).serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(uint16 chainId, uint128 assetId, uint8 decimals) external auth {
        if (chainId == localCentrifugeId) {
            hub.registerAsset(AssetId.wrap(assetId), decimals);
        } else {
            gateway.send(chainId, MessageLib.RegisterAsset({assetId: assetId, decimals: decimals}).serialize());
        }
    }
}
