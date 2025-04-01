// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {Auth} from "src/misc/Auth.sol";
import {D18} from "src/misc/types/D18.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";

import {MessageCategory, MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGasService} from "src/common/interfaces/IGasService.sol";
import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";
import {
    IInvestmentManagerGatewayHandler,
    IPoolManagerGatewayHandler,
    IPoolRouterGatewayHandler,
    IBalanceSheetManagerGatewayHandler
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

    /// @notice Dispatched when a message is attempted to be executed on the same chain, when that is not allowed.
    error LocalExecutionNotAllowed();

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

    IPoolRouterGatewayHandler public poolRouter;
    IPoolManagerGatewayHandler public poolManager;
    IInvestmentManagerGatewayHandler public investmentManager;
    IBalanceSheetManagerGatewayHandler public balanceSheetManager;

    uint16 public localCentrifugeId;

    constructor(uint16 centrifugeChainId_, IRoot root_, IGateway gateway_, address deployer) Auth(deployer) {
        localCentrifugeId = centrifugeChainId_;
        root = root_;
        gateway = gateway_;
    }

    /// @inheritdoc IMessageDispatcher
    function file(bytes32 what, address data) external auth {
        if (what == "poolRouter") poolRouter = IPoolRouterGatewayHandler(data);
        else if (what == "poolManager") poolManager = IPoolManagerGatewayHandler(data);
        else if (what == "investmentManager") investmentManager = IInvestmentManagerGatewayHandler(data);
        else if (what == "balanceSheetManager") balanceSheetManager = IBalanceSheetManagerGatewayHandler(data);
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
            poolManager.addTranche(poolId.raw(), scId.raw(), name, symbol, decimals, salt, address(bytes20(hook)));
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
    function sendInitiateMessageRecovery(uint16 chainId, bytes32 hash, uint16 adapterChainId, bytes32 adapter)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            gateway.initiateMessageRecovery(adapterChainId, IAdapter(address(bytes20(adapter))), hash);
        } else {
            gateway.send(chainId, MessageLib.InitiateMessageRecovery({hash: hash, adapter: adapter}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendDisputeMessageRecovery(uint16 chainId, bytes32 hash, uint16 adapterChainId, bytes32 adapter)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            gateway.disputeMessageRecovery(adapterChainId, IAdapter(address(bytes20(adapter))), hash);
        } else {
            gateway.send(chainId, MessageLib.DisputeMessageRecovery({hash: hash, adapter: adapter}).serialize());
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendTransferShares(uint16 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external
        auth
    {
        if (chainId == localCentrifugeId) {
            poolManager.handleTransferTrancheTokens(poolId, scId, address(bytes20(recipient)), amount);
        } else {
            gateway.send(
                chainId,
                MessageLib.TransferShares({poolId: poolId, scId: scId, recipient: recipient, amount: amount}).serialize(
                )
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external
        auth
    {
        if (PoolId.wrap(poolId).chainId() == localCentrifugeId) {
            poolRouter.depositRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount
            );
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
            poolRouter.redeemRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId), amount
            );
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
            poolRouter.cancelDepositRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId)
            );
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
            poolRouter.cancelRedeemRequest(
                PoolId.wrap(poolId), ShareClassId.wrap(scId), investor, AssetId.wrap(assetId)
            );
        } else {
            gateway.send(
                PoolId.wrap(poolId).chainId(),
                MessageLib.CancelRedeemRequest({poolId: poolId, scId: scId, investor: investor, assetId: assetId})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IVaultMessageSender
    function sendIncreaseHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: provider.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: true,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendDecreaseHolding(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: receiver.toBytes32(),
            amount: amount,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: false,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendUpdateHoldingValue(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        D18 pricePerUnit,
        uint256 timestamp
    ) external auth {
        JournalEntry[] memory debits = new JournalEntry[](0);
        JournalEntry[] memory credits = new JournalEntry[](0);

        MessageLib.UpdateHolding memory data = MessageLib.UpdateHolding({
            poolId: poolId.raw(),
            scId: scId.raw(),
            assetId: assetId.raw(),
            who: bytes32(0),
            amount: 0,
            pricePerUnit: pricePerUnit,
            timestamp: timestamp,
            isIncrease: false,
            debits: debits,
            credits: credits
        });

        gateway.send(poolId.chainId(), data.serialize());
    }

    /// @inheritdoc IVaultMessageSender
    function sendIssueShares(
        PoolId poolId,
        ShareClassId scId,
        address receiver,
        D18 pricePerShare,
        uint128 shares,
        uint256 timestamp
    ) external auth {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                who: receiver.toBytes32(),
                pricePerShare: pricePerShare,
                shares: shares,
                timestamp: timestamp,
                isIssuance: true
            }).serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        address provider,
        D18 pricePerShare,
        uint128 shares,
        uint256 timestamp
    ) external auth {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                who: provider.toBytes32(),
                pricePerShare: pricePerShare,
                shares: shares,
                timestamp: timestamp,
                isIssuance: false
            }).serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendJournalEntry(
        PoolId poolId,
        ShareClassId scId,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external auth {
        gateway.send(
            poolId.chainId(),
            MessageLib.UpdateJournal({poolId: poolId.raw(), scId: scId.raw(), debits: debits, credits: credits})
                .serialize()
        );
    }

    /// @inheritdoc IVaultMessageSender
    function sendRegisterAsset(
        uint16 chainId,
        uint128 assetId,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external auth {
        if (chainId == localCentrifugeId) {
            poolRouter.registerAsset(AssetId.wrap(assetId), name, symbol, decimals);
        } else {
            gateway.send(
                chainId,
                MessageLib.RegisterAsset({assetId: assetId, name: name, symbol: symbol.toBytes32(), decimals: decimals})
                    .serialize()
            );
        }
    }
}
