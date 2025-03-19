// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

/// @notice Interface for dispatch-only gateway
interface IPoolMessageSender {
    /// @notice Creates and send the message
    function sendNotifyPool(uint32 chainId, PoolId poolId) external;

    /// @notice Creates and send the message
    function sendNotifyShareClass(
        uint32 chainId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external;

    /// @notice Creates and send the message
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external;

    /// @notice Creates and send the message
    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 assetAmount,
        uint128 shareAmount
    ) external;

    /// @notice Creates and send the message
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledAmount
    ) external;

    /// @notice Creates and send the message
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint128 cancelledShares
    ) external;
}

/// @notice Interface for dispatch-only gateway
interface IVaultMessageSender {
    /// @notice Creates and send the message
    function sendTransferShares(uint32 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external;

    /// @notice Creates and send the message
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external;

    /// @notice Creates and send the message
    function sendRegisterAsset(
        uint32 chainId,
        uint128 assetId,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) external;
}
