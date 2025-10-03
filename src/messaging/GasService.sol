// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "./interfaces/IGasService.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "./libraries/MessageLib.sol";

import {IMessageLimits} from "../core/interfaces/IMessageLimits.sol";

/// @title  GasService
/// @notice This contract stores the gas limits (in gas units) for cross-chain message execution.
///         These values are used by adapters to determine how much gas to allocate for
///         message execution on destination chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account Adapter + Gateway processing + some mismatch happened regarding the input values
    uint128 public constant BASE_COST = 50_000;

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

    constructor() {
        // NOTE: Below values should be updated using script/utils/benchmark.sh
        scheduleUpgrade = BASE_COST + 93774;
        cancelUpgrade = BASE_COST + 74181;
        recoverTokens = BASE_COST + 148872;
        registerAsset = BASE_COST + 103846;
        setPoolAdapters = BASE_COST + 481520; // using MAX_ADAPTER_COUNT
        request = BASE_COST + 220898;
        notifyPool = BASE_COST + 1150707; // create escrow case
        notifyShareClass = BASE_COST + 1852918;
        notifyPricePoolPerShare = BASE_COST + 106973;
        notifyPricePoolPerAsset = BASE_COST + 111000;
        notifyShareMetadata = BASE_COST + 121365;
        updateShareHook = BASE_COST + 96294;
        initiateTransferShares = BASE_COST + 283163;
        executeTransferShares = BASE_COST + 177440;
        updateRestriction = BASE_COST + 114401;
        updateContract = BASE_COST + 144523;
        requestCallback = BASE_COST + 257981; // approve deposit case
        updateVaultDeployAndLink = BASE_COST + 2852862;
        updateVaultLink = BASE_COST + 185193;
        updateVaultUnlink = BASE_COST + 133911;
        setRequestManager = BASE_COST + 100471;
        updateBalanceSheetManager = BASE_COST + 104035;
        updateHoldingAmount = BASE_COST + 304286;
        updateShares = BASE_COST + 183886;
        maxAssetPriceAge = BASE_COST + 110070;
        maxSharePriceAge = BASE_COST + 106971;
        updateGatewayManager = BASE_COST + 87969;
    }

    /// @inheritdoc IMessageLimits
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
