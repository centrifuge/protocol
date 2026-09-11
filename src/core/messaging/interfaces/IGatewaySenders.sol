// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {VaultUpdateKind, ManagerKind} from "../libraries/MessageLib.sol";

/// @notice Share class metadata carried by the NotifyShareClass message, bundled to keep the sender signature
///         (and its callers' stack) within limits.
struct ShareClassMetadata {
    string name;
    string symbol;
    uint8 decimals;
}

interface ILocalCentrifugeId {
    error CannotBeSentLocally();

    function localCentrifugeId() external view returns (uint16);
}

/// @notice Interface for dispatch-only gateway
interface IScheduleAuthMessageSender {
    /// @notice Creates and send the message
    function sendScheduleUpgrade(uint16 centrifugeId, bytes32 target, address refund) external payable;

    /// @notice Creates and send the message
    function sendCancelUpgrade(uint16 centrifugeId, bytes32 target, address refund) external payable;
}

/// @notice Interface for dispatch-only gateway
interface IHubMessageSender is ILocalCentrifugeId {
    /// @notice Creates and send the message
    function sendNotifyPool(uint16 centrifugeId, PoolId poolId, address refund) external payable;

    /// @notice Creates and send the message
    function sendNotifyShareClass(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        ShareClassMetadata memory metadata,
        bytes32 salt,
        bytes32 registrar,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendNotifyShareMetadata(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        string memory name,
        string memory symbol,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendNotifyPricePoolPerShare(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        D18 pricePoolPerShare,
        uint64 computedAt,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendNotifyPricePoolPerAsset(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        D18 pricePoolPerAsset,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendUpdateRestriction(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Routes a manager call to its target. Local: through the `Envoy`, forwarding `value`. Remote:
    ///         emits a `ManagerCallFromHub` message delivered on the destination chain via its `Envoy`.
    /// @dev    `Hub.managerCall` enforces `value == msgValue()` locally / `value == 0` remotely. `extraGasLimit`
    ///         meters the remote delivery (inert on the local branch).
    function sendManagerCallFromHub(
        uint16 centrifugeId,
        PoolId poolId,
        address target,
        bytes calldata payload,
        uint128 extraGasLimit,
        uint256 value,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendUpdateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 vaultOrFactory,
        VaultUpdateKind kind,
        bytes calldata payload,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendSetRequestManager(uint16 centrifugeId, PoolId poolId, bytes32 manager, address refund) external payable;

    /// @notice Creates and send the message
    function sendSetPolicy(uint16 centrifugeId, PoolId poolId, bytes32 policy, address refund) external payable;

    /// @notice Creates and send the message
    function sendAuthorizeSpokeCall(uint16 centrifugeId, PoolId poolId, bytes calldata data, address refund)
        external
        payable;

    /// @notice Creates and send the message
    function sendUnauthorizeSpokeCall(uint16 centrifugeId, PoolId poolId, bytes calldata data, address refund)
        external
        payable;

    /// @notice Creates and send the message
    function sendUpdateManager(
        uint16 centrifugeId,
        PoolId poolId,
        ManagerKind kind,
        bytes32 who,
        bool canManage,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendExecuteTransferShares(
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendRequestCallback(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool unpaidMode,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendSetPoolAdapters(
        uint16 centrifugeId,
        PoolId poolId,
        bytes32[] memory adapters,
        uint8 threshold,
        uint16 targetSessionId,
        address refund
    ) external payable;
}

/// @notice Interface for dispatch-only gateway
interface ISpokeMessageSender is ILocalCentrifugeId {
    struct UpdateData {
        uint128 netAmount;
        bool isIncrease;
        bool isSnapshot;
        uint64 nonce;
    }

    /// @notice Creates and send the message
    function sendInitiateTransferShares(
        uint16 centrifugeId,
        PoolId poolId,
        ShareClassId scId,
        bytes32 sender,
        bytes32 receiver,
        uint128 amount,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendRegisterAsset(uint16 centrifugeId, AssetId assetId, uint8 decimals, address refund) external payable;

    /// @notice Creates and send the message
    /// @dev    The message carries no price; the hub values the delta at its own valuation.
    function sendUpdateAssets(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        UpdateData calldata data,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    /// @dev    ABI-compatibility overload of `sendUpdateAssets` for the deployed v3.1.0 BalanceSheet; the price
    ///         is ignored (the hub values the delta at its own valuation).
    function sendUpdateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        UpdateData calldata data,
        D18 pricePoolPerAsset,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendUpdateShares(
        PoolId poolId,
        ShareClassId scId,
        UpdateData calldata data,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Creates and send the message
    function sendRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes calldata payload,
        uint128 extraGasLimit,
        bool unpaidMode,
        address refund
    ) external payable;

    /// @notice Creates and sends a ManagerCallFromSpoke message, routed on the destination to the target's
    ///         `IManagerCallFromSpoke.fromSpoke` via the Envoy. The target validates `(centrifugeId, sender)`.
    /// @param poolId The pool identifier
    /// @param target The destination target contract (as bytes32)
    /// @param payload The action payload (any scId is encoded here)
    /// @param sender The spoke-side initiator (as bytes32)
    /// @param extraGasLimit Additional gas for cross-chain execution
    /// @param refund Address to refund excess payment
    function sendManagerCallFromSpoke(
        PoolId poolId,
        bytes32 target,
        bytes calldata payload,
        bytes32 sender,
        uint128 extraGasLimit,
        address refund
    ) external payable;
}
