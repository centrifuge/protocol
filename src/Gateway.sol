// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IGateway} from "src/interfaces/IGateway.sol";
import {IPoolManagerHandler} from "src/interfaces/IPoolManager.sol";

import {CastLib} from "src/libraries/CastLib.sol";

import {Auth} from "src/Auth.sol";

import {
    MessageType,
    SerializationLib,
    DeserializationLib,
    RegisterAssetMsg,
    AddPoolMsg,
    AddTrancheMsg,
    AllowAssetMsg,
    DisallowAssetMsg,
    TransferAssetsMsg
} from "src/libraries/MessageLib.sol";

interface IRouter {
    function sendMessage(uint32 chainId, bytes memory message) external;
}

contract Gateway is Auth, IGateway {
    using DeserializationLib for bytes;
    using CastLib for string;
    using CastLib for bytes;
    using CastLib for bytes32;

    IRouter public router;
    IPoolManagerHandler public handler;

    constructor(IRouter router_, address deployer) Auth(deployer) {
        router = router_;
    }

    function sendNotifyPool(uint32 chainId, PoolId poolId) external auth {
        router.sendMessage(chainId, AddPoolMsg(poolId.raw()).serialize());
    }

    function sendNotifyShareClass(
        uint32 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 hook
    ) external auth {
        router.sendMessage(
            chainId,
            AddTrancheMsg(poolId.raw(), scId.toBytes(), bytes(name), symbol.toBytes32(), decimals, hook).serialize()
        );
    }

    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external auth {
        bytes memory message = isAllowed
            ? AllowAssetMsg(poolId.raw(), assetId.raw()).serialize()
            : DisallowAssetMsg(poolId.raw(), assetId.raw()).serialize();
        router.sendMessage(assetId.chainId(), message);
    }

    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shares,
        uint128 investedAmount
    ) external auth {
        //TODO
    }

    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 shares,
        uint128 investedAmount
    ) external auth {
        //TODO
    }

    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 canceledAmount,
        uint128 fulfilledInvestedAmount
    ) external auth {
        //TODO
    }

    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 canceledShares,
        uint128 fulfilledInvestedAmount
    ) external auth {
        //TODO
    }

    function sendUnlockAssets(AssetId assetId, bytes32 receiver, uint128 assetAmount) external auth {
        router.sendMessage(assetId.chainId(), TransferAssetsMsg(assetId.raw(), receiver, assetAmount).serialize());
    }

    function handleMessage(bytes calldata message) external auth {
        MessageType kind = message.messageType();

        if (kind == MessageType.RegisterAsset) {
            RegisterAssetMsg memory data = message.deserializeRegisterAssetMsg();
            handler.handleRegisterAsset(
                AssetId.wrap(data.assetId), data.name.bytes128ToString(), data.symbol.toString(), data.decimals
            );
        } else if (kind == MessageType.TransferAssets) {
            TransferAssetsMsg memory data = message.deserializeTransferAssetsMsg();
            handler.handleLockedTokens(AssetId.wrap(data.assetId), address(bytes20(data.receiver)), data.amount);
        }
    }
}
