// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";

import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";
import {IMessageProperties} from "../../../src/common/interfaces/IMessageProperties.sol";
import {IMessageProcessor} from "../../../src/common/interfaces/IMessageProcessor.sol";

string constant FILE_PATH = "snapshots/MessageGasLimits.json";

contract MessageBenchmarker is IMessageProcessor, Test {
    using MessageLib for *;

    IMessageProcessor public immutable messageProcessor;

    constructor(IMessageProcessor messageProcessor_) {
        messageProcessor = messageProcessor_;
    }

    /// @inheritdoc IMessageProcessor
    function file(bytes32 what, address data) external {
        messageProcessor.file(what, data);
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external {
        _cleanFirstFileInteraction();

        string memory json = vm.readFile(FILE_PATH);
        string memory name = _getName(message);

        uint256 prev = _getPreviousRegisteredValue(json, string.concat("$.", name));
        uint256 before = gasleft();

        messageProcessor.handle(centrifugeId, message);

        uint256 new_ = before - gasleft();
        uint256 higher = prev > new_ ? prev : new_;

        //NOTE: If add a new entry, add first the name in the file, i.e: "newEntry" : 0
        vm.writeJson(vm.toString(higher), FILE_PATH, string.concat("$.", name));
    }

    /// @inheritdoc IMessageProperties
    function messageLength(bytes calldata message) external view returns (uint16) {
        return messageProcessor.messageLength(message);
    }

    /// @inheritdoc IMessageProperties
    function messagePoolId(bytes calldata message) external view returns (PoolId) {
        return messageProcessor.messagePoolId(message);
    }

    /// @inheritdoc IMessageProperties
    function messagePoolIdPayment(bytes calldata message) external view returns (PoolId) {
        return messageProcessor.messagePoolIdPayment(message);
    }

    function _getName(bytes calldata message) internal pure returns (string memory) {
        MessageType kind = message.messageType();
        if (kind == MessageType.ScheduleUpgrade) return "scheduleUpgrade";
        if (kind == MessageType.CancelUpgrade) return "cancelUpgrade";
        if (kind == MessageType.RecoverTokens) return "recoverTokens";
        if (kind == MessageType.RegisterAsset) return "registerAsset";
        if (kind == MessageType.SetPoolAdapters) return "setPoolAdapters";
        if (kind == MessageType.Request) return "request";
        if (kind == MessageType.NotifyPool) return "notifyPool";
        if (kind == MessageType.NotifyShareClass) return "notifyShareClass";
        if (kind == MessageType.NotifyPricePoolPerShare) return "notifyPricePoolPerShare";
        if (kind == MessageType.NotifyPricePoolPerAsset) return "notifyPricePoolPerAsset";
        if (kind == MessageType.NotifyShareMetadata) return "notifyShareMetadata";
        if (kind == MessageType.UpdateShareHook) return "updateShareHook";
        if (kind == MessageType.InitiateTransferShares) return "initiateTransferShares";
        if (kind == MessageType.ExecuteTransferShares) return "executeTransferShares";
        if (kind == MessageType.UpdateRestriction) return "updateRestriction";
        if (kind == MessageType.UpdateContract) return "updateContract";
        if (kind == MessageType.RequestCallback) return "requestCallback";
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return "updateVaultDeployAndLink";
            if (vaultKind == VaultUpdateKind.Link) return "updateVaultLink";
            if (vaultKind == VaultUpdateKind.Unlink) return "updateVaultUnlink";
            revert("Cannot benchmark message"); // Unreachable
        }
        if (kind == MessageType.SetRequestManager) return "setRequestManager";
        if (kind == MessageType.UpdateBalanceSheetManager) return "updateBalanceSheetManager";
        if (kind == MessageType.UpdateHoldingAmount) return "updateHoldingAmount";
        if (kind == MessageType.UpdateShares) return "updateShares";
        if (kind == MessageType.MaxAssetPriceAge) return "maxAssetPriceAge";
        if (kind == MessageType.MaxSharePriceAge) return "maxSharePriceAge";
        if (kind == MessageType.UpdateGatewayManager) return "updateGatewayManager";
        revert("Cannot benchmark message"); // Unreachable
    }

    function _getPreviousRegisteredValue(string memory file_, string memory path) internal pure returns (uint256) {
        try vm.parseJsonUint(file_, path) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    /// Because the final results will be the higher ones,
    /// we need to clean all previous results (from previous runs) in case there are some lower values
    /// Recommend to provide BENCHMARKING_RUN_ID as: BENCHMARKING_RUN_ID="$(date +%s)"
    function _cleanFirstFileInteraction() internal {
        uint256 newRunId = vm.envUint("BENCHMARKING_RUN_ID");

        string memory json = vm.readFile(FILE_PATH);
        uint256 fileRunId = _getPreviousRegisteredValue(json, "$.BENCHMARKING_RUN_ID");

        if (fileRunId != newRunId) {
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 i; i < keys.length; i++) {
                vm.writeJson("0", FILE_PATH, string.concat("$.", keys[i]));
            }

            vm.writeJson(vm.toString(newRunId), FILE_PATH, "$.BENCHMARKING_RUN_ID");
        }
    }
}
