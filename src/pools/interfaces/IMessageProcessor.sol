// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";

/// @notice Interface for dispatch-only gateway
interface IMessageProcessor {
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
    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external;

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

    /// @notice Creates and send the message
    function sendUpdateContractVaultUpdate(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 target,
        bytes32 factory,
        bytes32 vault,
        bool link
    ) external;
}
