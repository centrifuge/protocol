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
    uint128 public immutable setPoolAdapters;
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
    uint128 public immutable updateGatewayManager;

    constructor(uint128 maxBatchGasLimit_) {
        _maxBatchGasLimit = maxBatchGasLimit_;

        // NOTE: Below values should be updated using script/utils/benchmark.sh
        scheduleUpgrade = BASE_COST + 34062;
        cancelUpgrade = BASE_COST + 14469;
        recoverTokens = BASE_COST + 87322;
        registerAsset = BASE_COST + 44795;
        setPoolAdapters = BASE_COST + 416884; // using MAX_ADAPTER_COUNT
        request = BASE_COST + 336276;
        notifyPool = BASE_COST + 1166002; // create escrow case
        notifyShareClass = BASE_COST + 1784490;
        notifyPricePoolPerShare = BASE_COST + 42424;
        notifyPricePoolPerAsset = BASE_COST + 45788;
        notifyShareMetadata = BASE_COST + 54228;
        updateShareHook = BASE_COST + 31780;
        initiateTransferShares = BASE_COST + 188316;
        executeTransferShares = BASE_COST + 82524;
        updateRestriction = BASE_COST + 48809;
        updateContract = BASE_COST + 66627;
        requestCallback = BASE_COST + 197881; // approve deposit case
        updateVaultDeployAndLink = BASE_COST + 2772059;
        updateVaultLink = BASE_COST + 109091;
        updateVaultUnlink = BASE_COST + 57809;
        setRequestManager = BASE_COST + 40755;
        updateBalanceSheetManager = BASE_COST + 39376;
        updateHoldingAmount = BASE_COST + 239190;
        updateShares = BASE_COST + 119026;
        maxAssetPriceAge = BASE_COST + 45543;
        maxSharePriceAge = BASE_COST + 42429;
        updateGatewayManager = BASE_COST + 36959;
    }

    /// @inheritdoc IGasService
    function maxBatchGasLimit(uint16) public view returns (uint128) {
        return _maxBatchGasLimit;
    }

    /// @inheritdoc IGasService
    function messageGasLimit(uint16, bytes calldata message) public view returns (uint128) {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) return scheduleUpgrade;
        if (kind == MessageType.CancelUpgrade) return cancelUpgrade;
        if (kind == MessageType.RecoverTokens) return recoverTokens;
        if (kind == MessageType.RegisterAsset) return registerAsset;
        if (kind == MessageType.SetPoolAdapters) return setPoolAdapters;
        if (kind == MessageType.Request) return request;
        if (kind == MessageType.NotifyPool) return notifyPool;
        if (kind == MessageType.NotifyShareClass) return notifyShareClass;
        if (kind == MessageType.NotifyPricePoolPerShare) return notifyPricePoolPerShare;
        if (kind == MessageType.NotifyPricePoolPerAsset) return notifyPricePoolPerAsset;
        if (kind == MessageType.NotifyShareMetadata) return notifyShareMetadata;
        if (kind == MessageType.UpdateShareHook) return updateShareHook;
        if (kind == MessageType.InitiateTransferShares) return initiateTransferShares;
        if (kind == MessageType.ExecuteTransferShares) return executeTransferShares;
        if (kind == MessageType.UpdateRestriction) return updateRestriction;
        if (kind == MessageType.UpdateContract) return updateContract;
        if (kind == MessageType.RequestCallback) return requestCallback;
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return updateVaultDeployAndLink;
            if (vaultKind == VaultUpdateKind.Link) return updateVaultLink;
            if (vaultKind == VaultUpdateKind.Unlink) return updateVaultUnlink;
            revert InvalidMessageType(); // Unreachable
        }
        if (kind == MessageType.SetRequestManager) return setRequestManager;
        if (kind == MessageType.UpdateBalanceSheetManager) return updateBalanceSheetManager;
        if (kind == MessageType.UpdateHoldingAmount) return updateHoldingAmount;
        if (kind == MessageType.UpdateShares) return updateShares;
        if (kind == MessageType.MaxAssetPriceAge) return maxAssetPriceAge;
        if (kind == MessageType.MaxSharePriceAge) return maxSharePriceAge;
        if (kind == MessageType.UpdateGatewayManager) return updateGatewayManager;
        revert InvalidMessageType(); // Unreachable
    }
}
