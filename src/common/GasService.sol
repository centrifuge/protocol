// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "./libraries/MessageLib.sol";

/// @title  GasService
/// @notice This contract stores the gas limits (in gas units) for cross-chain message execution.
///         These values are used by adapters to determine how much gas to allocate for
///         message execution on destination chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account Adapter + Gateway processing + some mismatch happened regarding the input values
    uint128 public constant BASE_COST = 200_000;

    uint128 internal immutable _maxBatchGasLimit;

    uint128 public immutable scheduleUpgrade;
    uint128 public immutable cancelUpgrade;
    uint128 public immutable recoverTokens;
    uint128 public immutable registerAsset;
    uint128 public immutable request;
    uint128 public immutable notifyPool;
    uint128 public immutable notifyShareClass;
    uint128 public immutable notifyPricePoolPerShare;
    uint128 public immutable notifyPricePoolPerAsset;
    uint128 public immutable notifyShareMetadata;
    uint128 public immutable updateShareHook;
    uint128 public immutable initiateTransferShares;
    uint128 public immutable executeTransferShares;
    uint128 public immutable updateRestriction;
    uint128 public immutable updateContract;
    uint128 public immutable requestCallback;
    uint128 public immutable updateVaultDeployAndLink;
    uint128 public immutable updateVaultLink;
    uint128 public immutable updateVaultUnlink;
    uint128 public immutable setRequestManager;
    uint128 public immutable updateBalanceSheetManager;
    uint128 public immutable updateHoldingAmount;
    uint128 public immutable updateShares;
    uint128 public immutable maxAssetPriceAge;
    uint128 public immutable maxSharePriceAge;

    constructor(uint128 maxBatchGasLimit_) {
        _maxBatchGasLimit = maxBatchGasLimit_;

        // NOTE: The hardcoded values are take from the EndToEnd tests. This should be automated in the future.
        scheduleUpgrade = BASE_COST + 28514;
        cancelUpgrade = BASE_COST + 8861;
        recoverTokens = BASE_COST + 82906;
        registerAsset = BASE_COST + 34329;
        request = BASE_COST + 86084; // request deposit case
        notifyPool = BASE_COST + 1154806; // create escrow case
        notifyShareClass = BASE_COST + 1775916;
        notifyPricePoolPerShare = BASE_COST + 30496;
        notifyPricePoolPerAsset = BASE_COST + 35759;
        notifyShareMetadata = BASE_COST + 13343;
        updateShareHook = BASE_COST + 6415;
        initiateTransferShares = BASE_COST + 52195;
        executeTransferShares = BASE_COST + 70267;
        updateRestriction = BASE_COST + 35992;
        updateContract = BASE_COST + 53345;
        requestCallback = BASE_COST + 186947; // approve deposit case
        updateVaultDeployAndLink = BASE_COST + 2770342;
        updateVaultLink = BASE_COST + 100567;
        updateVaultUnlink = BASE_COST + 20814;
        setRequestManager = BASE_COST + 30039;
        updateBalanceSheetManager = BASE_COST + 35241;
        updateHoldingAmount = BASE_COST + 220866;
        updateShares = BASE_COST + 49968;
        maxAssetPriceAge = BASE_COST + 27260;
        maxSharePriceAge = BASE_COST + 26032;
    }

    /// @inheritdoc IGasService
    function maxBatchGasLimit(uint16) public view returns (uint128) {
        return _maxBatchGasLimit;
    }

    /// @inheritdoc IGasService
    function messageGasLimit(uint16, bytes calldata message) public view returns (uint128) {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) {
            return scheduleUpgrade;
        } else if (kind == MessageType.CancelUpgrade) {
            return cancelUpgrade;
        } else if (kind == MessageType.RecoverTokens) {
            return recoverTokens;
        } else if (kind == MessageType.RegisterAsset) {
            return registerAsset;
        } else if (kind == MessageType.Request) {
            return request;
        } else if (kind == MessageType.NotifyPool) {
            return notifyPool;
        } else if (kind == MessageType.NotifyShareClass) {
            return notifyShareClass;
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            return notifyPricePoolPerShare;
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            return notifyPricePoolPerAsset;
        } else if (kind == MessageType.NotifyShareMetadata) {
            return notifyShareMetadata;
        } else if (kind == MessageType.UpdateShareHook) {
            return updateShareHook;
        } else if (kind == MessageType.InitiateTransferShares) {
            return initiateTransferShares;
        } else if (kind == MessageType.ExecuteTransferShares) {
            return executeTransferShares;
        } else if (kind == MessageType.UpdateRestriction) {
            return updateRestriction;
        } else if (kind == MessageType.UpdateContract) {
            return updateContract;
        } else if (kind == MessageType.RequestCallback) {
            return requestCallback;
        } else if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);

            if (vaultKind == VaultUpdateKind.DeployAndLink) {
                return updateVaultDeployAndLink;
            } else if (vaultKind == VaultUpdateKind.Link) {
                return updateVaultLink;
            } else if (vaultKind == VaultUpdateKind.Unlink) {
                return updateVaultUnlink;
            } else {
                revert InvalidMessageType(); // Unreachable
            }
        } else if (kind == MessageType.SetRequestManager) {
            return setRequestManager;
        } else if (kind == MessageType.UpdateBalanceSheetManager) {
            return updateBalanceSheetManager;
        } else if (kind == MessageType.UpdateHoldingAmount) {
            return updateHoldingAmount;
        } else if (kind == MessageType.UpdateShares) {
            return updateShares;
        } else if (kind == MessageType.MaxAssetPriceAge) {
            return maxAssetPriceAge;
        } else if (kind == MessageType.MaxSharePriceAge) {
            return maxSharePriceAge;
        } else {
            revert InvalidMessageType(); // Unreachable
        }
    }
}
