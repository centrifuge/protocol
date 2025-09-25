// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

string constant FILE_PATH = "snapshots/MessageGasLimits.json";

contract MessageBenchmarker is IMessageHandler, IAdapter, Test {
    using MessageLib for *;

    IMessageHandler public immutable messageHandler;
    IAdapter public immutable adapter;

    constructor(IMessageHandler messageHandler_, IAdapter adapter_) {
        messageHandler = messageHandler_;
        adapter = adapter_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external {
        _cleanFirstFileInteraction();

        string memory json = vm.readFile(FILE_PATH);
        string memory name = _getName(message);

        uint256 prev = _getPreviousRegisteredValue(json, string.concat("$.", name));
        uint256 before = gasleft();

        messageHandler.handle(centrifugeId, message);

        uint256 new_ = before - gasleft();
        uint256 higher = prev > new_ ? prev : new_;

        // NOTE: If add a new entry, add first thename in the snapshot file, i.e: "newEntry" : 0
        vm.writeJson(vm.toString(higher), FILE_PATH, string.concat("$.", name));
    }

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
        external
        payable
        returns (bytes32)
    {
        return adapter.send{value: msg.value}(centrifugeId, payload, gasLimit, refund);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        return adapter.estimate(centrifugeId, payload, gasLimit);
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
    /// we need to clean all previous results (from previous runs) in case there are some new lower values
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
