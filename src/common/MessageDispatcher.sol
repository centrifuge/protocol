// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {ShareClassId} from "./types/ShareClassId.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IRequestManager} from "./interfaces/IRequestManager.sol";
import {ITokenRecoverer} from "./interfaces/ITokenRecoverer.sol";
import {IMessageDispatcher} from "./interfaces/IMessageDispatcher.sol";
import {MessageLib, VaultUpdateKind} from "./libraries/MessageLib.sol";
import {ISpokeMessageSender, IHubMessageSender, IRootMessageSender} from "./interfaces/IGatewaySenders.sol";
import {
    ISpokeGatewayHandler,
    IBalanceSheetGatewayHandler,
    IHubGatewayHandler,
    IUpdateContractGatewayHandler
} from "./interfaces/IGatewayHandlers.sol";

import {Auth} from "../misc/Auth.sol";
import {D18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IRecoverable} from "../misc/interfaces/IRecoverable.sol";

contract MessageDispatcher is Auth, IMessageDispatcher {
    using CastLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using MathLib for uint256;

    PoolId internal constant GLOBAL_POOL = PoolId.wrap(0);

    IRoot public immutable root;
    ITokenRecoverer public immutable tokenRecoverer;

    uint16 public immutable localCentrifugeId;

    IGateway public gateway;
    IHubGatewayHandler public hub;
    ISpokeGatewayHandler public spoke;
    IMultiAdapter public multiAdapter;
    IBalanceSheetGatewayHandler public balanceSheet;
    IUpdateContractGatewayHandler public contractUpdater;

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
        else if (what == "spoke") spoke = ISpokeGatewayHandler(data);
        else if (what == "gateway") gateway = IGateway(gateway);
        else if (what == "balanceSheet") balanceSheet = IBalanceSheetGatewayHandler(data);
        else if (what == "contractUpdater") contractUpdater = IUpdateContractGatewayHandler(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubMessageSender
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            spoke.addPool(poolId);
        } else {
            return gateway.send(centrifugeId, MessageLib.NotifyPool({poolId: poolId.raw()}).serialize());
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
        bytes32 hook
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            spoke.addShareClass(poolId, scId, name, symbol, decimals, salt, hook.toAddress());
        } else {
            return gateway.send(
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

    /// @inheritdoc IHubMessageSender
    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            spoke.updateShareMetadata(poolId, scId, name, symbol);
        } else {
            return gateway.send(
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

    /// @inheritdoc IHubMessageSender
    function sendUpdateShareHook(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 hook)
        external
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            spoke.updateShareHook(poolId, scId, hook.toAddress());
        } else {
            return gateway.send(
                centrifugeId,
                MessageLib.UpdateShareHook({poolId: poolId.raw(), scId: scId.raw(), hook: hook}).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyPricePoolPerShare(uint16 chainId, PoolId poolId, ShareClassId scId, D18 price)
        external
        auth
        returns (uint256 cost)
    {
        uint64 timestamp = block.timestamp.toUint64();
        if (chainId == localCentrifugeId) {
            spoke.updatePricePoolPerShare(poolId, scId, price, timestamp);
        } else {
            return gateway.send(
                chainId,
                MessageLib.NotifyPricePoolPerShare({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    price: price.raw(),
                    timestamp: timestamp
                }).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendNotifyPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 price)
        external
        auth
        returns (uint256 cost)
    {
        uint64 timestamp = block.timestamp.toUint64();
        if (assetId.centrifugeId() == localCentrifugeId) {
            spoke.updatePricePoolPerAsset(poolId, scId, assetId, price, timestamp);
        } else {
            return gateway.send(
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

    /// @inheritdoc IHubMessageSender
    function sendUpdateRestriction(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            spoke.updateRestriction(poolId, scId, payload);
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                centrifugeId,
                MessageLib.UpdateRestriction({poolId: poolId.raw(), scId: scId.raw(), payload: payload}).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateContract(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            contractUpdater.execute(poolId, scId, target.toAddress(), payload);
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                centrifugeId,
                MessageLib.UpdateContract({poolId: poolId.raw(), scId: scId.raw(), target: target, payload: payload})
                    .serialize()
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
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (assetId.centrifugeId() == localCentrifugeId) {
            spoke.updateVault(poolId, scId, assetId, vaultOrFactory.toAddress(), kind);
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                assetId.centrifugeId(),
                MessageLib.UpdateVault({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    vaultOrFactory: vaultOrFactory,
                    kind: uint8(kind)
                }).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendSetRequestManager(uint16 centrifugeId, PoolId poolId, bytes32 manager)
        external
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            spoke.setRequestManager(poolId, IRequestManager(manager.toAddress()));
        } else {
            return gateway.send(
                centrifugeId, MessageLib.SetRequestManager({poolId: poolId.raw(), manager: manager}).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendUpdateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage)
        external
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            balanceSheet.updateManager(poolId, who.toAddress(), canManage);
        } else {
            return gateway.send(
                centrifugeId,
                MessageLib.UpdateBalanceSheetManager({poolId: poolId.raw(), who: who, canManage: canManage}).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge)
        external
        auth
        returns (uint256 cost)
    {
        if (assetId.centrifugeId() == localCentrifugeId) {
            spoke.setMaxAssetPriceAge(poolId, scId, assetId, maxPriceAge);
        } else {
            return gateway.send(
                assetId.centrifugeId(),
                MessageLib.MaxAssetPriceAge({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    maxPriceAge: maxPriceAge
                }).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge)
        external
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            spoke.setMaxSharePriceAge(poolId, scId, maxPriceAge);
        } else {
            return gateway.send(
                centrifugeId,
                MessageLib.MaxSharePriceAge({poolId: poolId.raw(), scId: scId.raw(), maxPriceAge: maxPriceAge})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            root.scheduleRely(target.toAddress());
        } else {
            return gateway.send(centrifugeId, MessageLib.ScheduleUpgrade({target: target}).serialize());
        }
    }

    /// @inheritdoc IRootMessageSender
    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            root.cancelRely(target.toAddress());
        } else {
            return gateway.send(centrifugeId, MessageLib.CancelUpgrade({target: target}).serialize());
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
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            tokenRecoverer.recoverTokens(
                IRecoverable(target.toAddress()), token.toAddress(), tokenId, to.toAddress(), amount
            );
        } else {
            return gateway.send(
                centrifugeId,
                MessageLib.RecoverTokens({target: target, token: token, tokenId: tokenId, to: to, amount: amount})
                    .serialize()
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendInitiateTransferShares(
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 remoteExtraGasLimit
    ) external payable auth returns (uint256 cost) {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.initiateTransferShares(
                localCentrifugeId, targetCentrifugeId, poolId, scId, receiver, amount, remoteExtraGasLimit
            );
        } else {
            require(!gateway.isBatching(), CannotBeBatched());
            gateway.depositSubsidy{value: msg.value}(poolId);
            cost = gateway.send(
                poolId.centrifugeId(),
                MessageLib.InitiateTransferShares({
                    centrifugeId: targetCentrifugeId,
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    receiver: receiver,
                    amount: amount,
                    extraGasLimit: remoteExtraGasLimit
                }).serialize()
            );
            require(msg.value >= cost, NotEnoughGasToSendMessage());
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
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (targetCentrifugeId == localCentrifugeId) {
            // Spoke chain X => Hub chain Y => Spoke chain Y
            spoke.executeTransferShares(poolId, scId, receiver, amount);
        } else {
            bytes memory message = MessageLib.ExecuteTransferShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                receiver: receiver,
                amount: amount
            }).serialize();

            gateway.setExtraGasLimit(extraGasLimit);

            if (originCentrifugeId == localCentrifugeId) {
                // Spoke chain X => Hub chain X => Spoke chain Y: payment done directly on X
                return gateway.send(targetCentrifugeId, message);
            } else {
                // Spoke chain X => Hub chain Y => Spoke chain Z
                gateway.addUnpaidMessage(targetCentrifugeId, message, false);
            }
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        UpdateData calldata data,
        D18 pricePoolPerAsset,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateHoldingAmount(
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
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateHoldingAmount({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    amount: data.netAmount,
                    pricePerUnit: pricePoolPerAsset.raw(),
                    timestamp: uint64(block.timestamp),
                    isIncrease: data.isIncrease,
                    isSnapshot: data.isSnapshot,
                    nonce: data.nonce
                }).serialize()
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendUpdateShares(PoolId poolId, ShareClassId scId, UpdateData calldata data, uint128 extraGasLimit)
        external
        auth
        returns (uint256 cost)
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.updateShares(
                localCentrifugeId, poolId, scId, data.netAmount, data.isIncrease, data.isSnapshot, data.nonce
            );
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                poolId.centrifugeId(),
                MessageLib.UpdateShares({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    shares: data.netAmount,
                    timestamp: uint64(block.timestamp),
                    isIssuance: data.isIncrease,
                    isSnapshot: data.isSnapshot,
                    nonce: data.nonce
                }).serialize()
            );
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals)
        external
        payable
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            hub.registerAsset(assetId, decimals);
        } else {
            require(!gateway.isBatching(), CannotBeBatched());
            gateway.depositSubsidy{value: msg.value}(GLOBAL_POOL);
            cost = gateway.send(
                centrifugeId, MessageLib.RegisterAsset({assetId: assetId.raw(), decimals: decimals}).serialize()
            );
            require(msg.value >= cost, NotEnoughGasToSendMessage());
        }
    }

    /// @inheritdoc ISpokeMessageSender
    function sendRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload)
        external
        auth
        returns (uint256 cost)
    {
        if (poolId.centrifugeId() == localCentrifugeId) {
            hub.request(poolId, scId, assetId, payload);
        } else {
            return gateway.send(
                poolId.centrifugeId(),
                MessageLib.Request({poolId: poolId.raw(), scId: scId.raw(), assetId: assetId.raw(), payload: payload})
                    .serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendRequestCallback(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external auth returns (uint256 cost) {
        if (assetId.centrifugeId() == localCentrifugeId) {
            spoke.requestCallback(poolId, scId, assetId, payload);
        } else {
            gateway.setExtraGasLimit(extraGasLimit);
            return gateway.send(
                assetId.centrifugeId(),
                MessageLib.RequestCallback({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    assetId: assetId.raw(),
                    payload: payload
                }).serialize()
            );
        }
    }

    /// @inheritdoc IHubMessageSender
    function sendSetPoolAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        bytes32[] memory adapters,
        uint8 threshold,
        uint8 recoveryIndex
    ) external auth returns (uint256 cost) {
        if (centrifugeId == localCentrifugeId) {
            revert CannotBeSentLocally();
        } else {
            return gateway.send(
                centrifugeId,
                MessageLib.SetPoolAdapters({
                    poolId: poolId.raw(),
                    threshold: threshold,
                    recoveryIndex: recoveryIndex,
                    adapterList: adapters
                }).serialize()
            );
        }
    }

    function sendSetGatewayManager(uint16 centrifugeId, PoolId poolId, bytes32 manager)
        external
        auth
        returns (uint256 cost)
    {
        if (centrifugeId == localCentrifugeId) {
            gateway.setManager(poolId, manager.toAddress());
        } else {
            return gateway.send(
                centrifugeId, MessageLib.SetGatewayManager({poolId: poolId.raw(), manager: manager}).serialize()
            );
        }
    }
}
