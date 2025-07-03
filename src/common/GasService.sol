// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGasService} from "src/common/interfaces/IGasService.sol";
import {MessageLib, MessageType} from "src/common/libraries/MessageLib.sol";

/// @title  GasService
/// @notice This is a utility contract used to determine the execution gas limit
///         for a payload being sent across all supported adapters.
contract GasService is IGasService {
    using MessageLib for *;

    /// @dev Takes into account Adapter + Gateway processing + some mismatch happened regarding the reference
    uint128 public constant BASE_COST = 200_000;
    /// @dev Assumess a relatively small computation for unknown/non-measured code paths
    uint128 public constant SMALL_COST = 100_000;

    uint128 internal immutable _batchGasLimit;
    uint128 internal immutable _messageGasLimit;

    constructor(uint128 batchGasLimit_, uint128 messageGasLimit_) {
        _batchGasLimit = batchGasLimit_;
        _messageGasLimit = messageGasLimit_;
    }

    /// @inheritdoc IGasService
    function batchGasLimit(uint16) public view returns (uint128) {
        return _batchGasLimit;
    }

    /// @inheritdoc IGasService
    function messageGasLimit(uint16, bytes calldata message) public view returns (uint128) {
        MessageType kind = message.messageType();

        if (kind == MessageType.ScheduleUpgrade) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.CancelUpgrade) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.RecoverTokens) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.RegisterAsset) {
            return BASE_COST + 34329; // hub.registerAsset()
        } else if (kind == MessageType.Request) {
            return BASE_COST + 86084; // hub.request(requestDeposit)
        } else if (kind == MessageType.NotifyPool) {
            return BASE_COST + 38190; // spoke.notifyPool()
        } else if (kind == MessageType.NotifyShareClass) {
            return BASE_COST + 1775916; // spoke.notifyShareClass()
        } else if (kind == MessageType.NotifyPricePoolPerShare) {
            return BASE_COST + 30496; // spoke.updatePricePoolPerShare()
        } else if (kind == MessageType.NotifyPricePoolPerAsset) {
            return BASE_COST + 35759; // spoke.updatePricePoolPerAsset()
        } else if (kind == MessageType.NotifyShareMetadata) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.UpdateShareHook) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.InitiateTransferShares) {
            return BASE_COST + 52195; // hub.initiateTransferShares
        } else if (kind == MessageType.ExecuteTransferShares) {
            return BASE_COST + 70267; // spoke.executeTransferShares
        } else if (kind == MessageType.UpdateRestriction) {
            return BASE_COST + 35992;
        } else if (kind == MessageType.UpdateContract) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.RequestCallback) {
            return BASE_COST + 186947; // spoke.requestCallback(approveDeposit)
        } else if (kind == MessageType.UpdateVault) {
            return BASE_COST + 2770342; // spoke.updateVault(deploy)
        } else if (kind == MessageType.SetRequestManager) {
            return BASE_COST + 30039; // spoke.setRequestManager()
        } else if (kind == MessageType.UpdateBalanceSheetManager) {
            return BASE_COST + 35241; // balanceSheet.updateManager()
        } else if (kind == MessageType.UpdateHoldingAmount) {
            return BASE_COST + 220866; // hub.updateHoldingAmount
        } else if (kind == MessageType.UpdateShares) {
            return BASE_COST + 49968; // hub.updateShares
        } else if (kind == MessageType.MaxAssetPriceAge) {
            return BASE_COST + SMALL_COST;
        } else if (kind == MessageType.MaxSharePriceAge) {
            return BASE_COST + SMALL_COST;
        } else {
            return _messageGasLimit;
        }
    }
}
