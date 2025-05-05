// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

interface ILocalCentrifugeId {
    function localCentrifugeId() external view returns (uint16);
}

/// @notice Interface for dispatch-only gateway
interface IRootMessageSender {
    /// @notice Creates and send the message
    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target) external;

    /// @notice Creates and send the message
    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target) external;

    /// @notice Creates and send the message
    function sendRecoverTokens(
        uint16 centrifugeId,
        bytes32 target,
        bytes32 token,
        uint256 tokenId,
        bytes32 to,
        uint256 amount
    ) external;

    /// @notice Creates and send the message
    function sendInitiateRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external;

    /// @notice Creates and send the message
    function sendDisputeRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, bytes32 adapter, bytes32 hash)
        external;
}

/// @notice Interface for dispatch-only gateway
interface IPoolMessageSender is ILocalCentrifugeId {
    /// @notice Creates and send the message
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId) external;

    /// @notice Creates and send the message
    function sendNotifyShareClass(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        bytes32 hook
    ) external;

    /// @notice Creates and send the message
    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol
    ) external;

    /// @notice Creates and send the message
    function sendUpdateShareHook(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 hook) external;

    /// @notice Creates and send the message
    function sendNotifyPricePoolPerShare(uint16 chainId, PoolId poolId, ShareClassId scId, D18 pricePerShare)
        external;

    /// @notice Creates and send the message
    function sendNotifyPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePerShare)
        external;

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
    function sendUpdateRestriction(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes calldata payload)
        external;

    /// @notice Creates and send the message
    function sendUpdateContract(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload
    ) external;

    /// @notice Creates and send the message
    function sendApprovedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external;

    // @notice Creates and send the message
    function sendIssuedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external;

    /// @notice Creates and send the message
    function sendRevokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external;

    /// @notice Creates and send the message
    function sendTriggerIssueShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, address who, uint128 shares)
        external;

    /// @notice Creates and send the message
    function sendTriggerSubmitQueuedShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId) external;

    /// @notice Creates and send the message
    function sendTriggerSubmitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external;

    /// @notice Creates and send the message
    function sendSetQueue(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bool enabled) external;
}

/// @notice Interface for dispatch-only gateway
interface IVaultMessageSender is ILocalCentrifugeId {
    /// @notice Creates and send the message
    function sendTransferShares(uint16 centrifugeId, PoolId poolId, ShareClassId scId, bytes32 receiver, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendCancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId) external;

    /// @notice Creates and send the message
    function sendCancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId assetId) external;

    /// @notice Creates and send the message
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals) external;

    /// @notice Creates and send the message
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address provider,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease
    ) external;

    /// @notice Creates and send the message
    function sendUpdateShares(PoolId poolId, ShareClassId scId, uint128 shares, bool isIssuance) external;
}
