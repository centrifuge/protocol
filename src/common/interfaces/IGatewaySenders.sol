// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

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
}

/// @notice Interface for dispatch-only gateway
interface IHubMessageSender is ILocalCentrifugeId {
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
    function sendUpdateRestriction(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external;

    /// @notice Creates and send the message
    function sendUpdateContract(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 target,
        bytes calldata payload,
        uint128 extraGasLimit
    ) external;

    /// @notice Creates and send the message
    function sendUpdateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        uint128 extraGasLimit
    ) external;

    /// @notice Creates and send the message
    function sendInitializeVaultManager(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 manager)
        external;

    /// @notice Creates and send the message
    function sendUpdateBalanceSheetManager(uint16 centrifugeId, PoolId poolId, bytes32 who, bool canManage) external;

    /// @notice Creates and send the message
    function sendExecuteTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    ) external;

    /// @notice Creates and send the message
    function sendMaxAssetPriceAge(PoolId poolId, ShareClassId scId, AssetId assetId, uint64 maxPriceAge) external;

    /// @notice Creates and send the message
    function sendMaxSharePriceAge(uint16 centrifugeId, PoolId poolId, ShareClassId scId, uint64 maxPriceAge) external;

    /// @notice Creates and send the message
    function sendRequestCallback(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}

/// @notice Interface for dispatch-only gateway
interface ISpokeMessageSender is ILocalCentrifugeId {
    /// @notice Creates and send the message
    function sendInitiateTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount
    ) external;

    /// @notice Creates and send the message
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals) external;

    /// @notice Creates and send the message
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce,
        uint128 extraGasLimit
    ) external;

    /// @notice Creates and send the message
    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        uint128 shares,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce,
        uint128 extraGasLimit
    ) external;

    /// @notice Creates and send the message
    function sendRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external;
}
