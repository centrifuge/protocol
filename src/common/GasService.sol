// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "src/common/interfaces/IGasService.sol";
import {MessageLib, MessageType} from "src/common/libraries/MessageLib.sol";

/// @title  GasService
/// @notice This contract stores the gas limits (in gas units) for cross-chain message execution.
///         These values are used by adapters to determine how much gas to allocate for 
///         message execution on destination chains.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account Adapter + Gateway processing + some mismatch happened regarding the reference
    uint128 public constant BASE_COST = 200_000;
    /// @dev Assumess a relatively small computation for unknown/non-measured code paths
    uint128 public constant SMALL_COST = 100_000;

    uint128 internal immutable _batchGasLimit;

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
    uint128 public immutable updateVault;
    uint128 public immutable setRequestManager;
    uint128 public immutable updateBalanceSheetManager;
    uint128 public immutable updateHoldingAmount;
    uint128 public immutable updateShares;
    uint128 public immutable maxAssetPriceAge;
    uint128 public immutable maxSharePriceAge;

    constructor(uint128 batchGasLimit_) {
        _batchGasLimit = batchGasLimit_;

        // NOTE: The hardcoded values are take from the EndToEnd tests. This should be automated in the future.

        scheduleUpgrade = BASE_COST + SMALL_COST;
        cancelUpgrade = BASE_COST + SMALL_COST;
        recoverTokens = BASE_COST + SMALL_COST;
        registerAsset = BASE_COST + 34329;
        request = BASE_COST + 86084; // request deposit case
        notifyPool = BASE_COST + 38190;
        notifyShareClass = BASE_COST + 1775916;
        notifyPricePoolPerShare = BASE_COST + 30496;
        notifyPricePoolPerAsset = BASE_COST + 35759;
        notifyShareMetadata = BASE_COST + SMALL_COST;
        updateShareHook = BASE_COST + SMALL_COST;
        initiateTransferShares = BASE_COST + 52195;
        executeTransferShares = BASE_COST + 70267;
        updateRestriction = BASE_COST + 35992;
        updateContract = BASE_COST + SMALL_COST;
        requestCallback = BASE_COST + 186947; // approve deposit case
        updateVault = BASE_COST + 2770342; // deploy vault case
        setRequestManager = BASE_COST + 30039;
        updateBalanceSheetManager = BASE_COST + 35241;
        updateHoldingAmount = BASE_COST + 220866;
        updateShares = BASE_COST + 49968;
        maxAssetPriceAge = BASE_COST + SMALL_COST;
        maxSharePriceAge = BASE_COST + SMALL_COST;
    }

    /// @inheritdoc IGasService
    function batchGasLimit(uint16) public view returns (uint128) {
        return _batchGasLimit;
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
            return updateVault;
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
            return type(uint128).max; // Unreachable
        }
    }
}
