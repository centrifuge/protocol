// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "../../../src/core/messaging/interfaces/IMessageHandler.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";

string constant FILE_PATH = "snapshots/MessageGasLimits.json";
string constant COLD_FILE_PATH = "snapshots/MessageColdAccesses.json";

contract MessageBenchmarker is IMessageHandler, Test {
    using MessageLib for *;

    IMessageHandler public messageHandler;

    function setHandler(IMessageHandler handler_) public {
        messageHandler = handler_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external {
        if (vm.envOr("BENCHMARK_COLD_ACCESSES", uint256(0)) == 1) {
            _recordColdAccesses(centrifugeId, message);
            return;
        }

        _cleanFirstFileInteraction(FILE_PATH);

        string memory json = vm.readFile(FILE_PATH);
        // Strip the 2-byte session ID prefix that MultiAdapter prepends to outgoing messages
        string memory name = _getName(message[2:]);

        uint256 prev = _getPreviousRegisteredValue(json, string.concat("$.", name));
        uint256 before = gasleft();

        messageHandler.handle(centrifugeId, message);

        uint256 new_ = before - gasleft();
        uint256 higher = prev > new_ ? prev : new_;

        // NOTE: If add a new entry, add first thename in the snapshot file, i.e: "newEntry" : 0
        vm.writeJson(vm.toString(higher), FILE_PATH, string.concat("$.", name));
    }

    /// @dev Runs as its own pass, because vm.startStateDiffRecording perturbs gas metering badly enough
    ///      (~25% under the real cost) that counts can never share a run with the gas benchmark.
    function _recordColdAccesses(uint16 centrifugeId, bytes calldata message) internal {
        _cleanFirstFileInteraction(COLD_FILE_PATH);

        string memory name = _getName(message[2:]);

        vm.startStateDiffRecording();
        messageHandler.handle(centrifugeId, message);
        (uint256 coldAccounts, uint256 coldSlots) = _countColdAccesses(vm.stopAndReturnStateDiff());

        _writeMax(COLD_FILE_PATH, string.concat(name, "Slots"), coldSlots);
        _writeMax(COLD_FILE_PATH, string.concat(name, "Accounts"), coldAccounts);
    }

    /// @dev Counts distinct accounts and (account, slot) pairs first touched while handling the message.
    ///      In production each is a cold access; the gas benchmark runs warm and never pays for them.
    ///      Reverted accesses are counted too, erring high.
    function _countColdAccesses(VmSafe.AccountAccess[] memory accesses)
        internal
        pure
        returns (uint256 coldAccounts, uint256 coldSlots)
    {
        uint256 slotCap;
        for (uint256 i; i < accesses.length; i++) {
            slotCap += accesses[i].storageAccesses.length;
        }

        address[] memory seenAccounts = new address[](accesses.length);
        bytes32[] memory seenSlots = new bytes32[](slotCap);

        for (uint256 i; i < accesses.length; i++) {
            if (!_seenAccount(seenAccounts, coldAccounts, accesses[i].account)) {
                seenAccounts[coldAccounts++] = accesses[i].account;
            }

            VmSafe.StorageAccess[] memory slots = accesses[i].storageAccesses;
            for (uint256 j; j < slots.length; j++) {
                bytes32 key = keccak256(abi.encodePacked(slots[j].account, slots[j].slot));
                if (!_seenSlot(seenSlots, coldSlots, key)) seenSlots[coldSlots++] = key;
            }
        }
    }

    function _seenAccount(address[] memory seen, uint256 len, address value) internal pure returns (bool) {
        for (uint256 i; i < len; i++) {
            if (seen[i] == value) return true;
        }
        return false;
    }

    function _seenSlot(bytes32[] memory seen, uint256 len, bytes32 value) internal pure returns (bool) {
        for (uint256 i; i < len; i++) {
            if (seen[i] == value) return true;
        }
        return false;
    }

    function _writeMax(string memory path, string memory key, uint256 value) internal {
        uint256 prev = _getPreviousRegisteredValue(vm.readFile(path), string.concat("$.", key));
        uint256 higher = prev > value ? prev : value;
        vm.writeJson(vm.toString(higher), path, string.concat("$.", key));
    }

    function _getName(bytes calldata message) internal pure returns (string memory) {
        MessageType kind = message.messageType();
        if (kind == MessageType.ScheduleUpgrade) return "scheduleUpgrade";
        if (kind == MessageType.CancelUpgrade) return "cancelUpgrade";
        if (kind == MessageType.RegisterAsset) return "registerAsset";
        if (kind == MessageType.SetPoolAdapters) return "setPoolAdapters";
        if (kind == MessageType.Request) return "request";
        if (kind == MessageType.NotifyPool) return "notifyPool";
        if (kind == MessageType.NotifyShareClass) return "notifyShareClass";
        if (kind == MessageType.NotifyPricePoolPerShare) return "notifyPricePoolPerShare";
        if (kind == MessageType.NotifyPricePoolPerAsset) return "notifyPricePoolPerAsset";
        if (kind == MessageType.NotifyShareMetadata) return "notifyShareMetadata";
        if (kind == MessageType.InitiateTransferShares) return "initiateTransferShares";
        if (kind == MessageType.ExecuteTransferShares) return "executeTransferShares";
        if (kind == MessageType.UpdateRestriction) return "updateRestriction";
        if (kind == MessageType.ManagerCallFromHub) return "managerCallFromHub";
        if (kind == MessageType.RequestCallback) return "requestCallback";
        if (kind == MessageType.UpdateVault) {
            VaultUpdateKind vaultKind = VaultUpdateKind(message.deserializeUpdateVault().kind);
            if (vaultKind == VaultUpdateKind.DeployAndLink) return "updateVaultDeployAndLink";
            if (vaultKind == VaultUpdateKind.Link) return "updateVaultLink";
            if (vaultKind == VaultUpdateKind.Unlink) return "updateVaultUnlink";
            revert("Cannot benchmark message"); // Unreachable
        }
        if (kind == MessageType.SetRequestManager) return "setRequestManager";
        if (kind == MessageType.SetPolicy) return "setPolicy";
        if (kind == MessageType.UpdateManager) return "updateManager";
        if (kind == MessageType.UpdateAssets) return "updateAssets";
        if (kind == MessageType.UpdateShares) return "updateShares";
        if (kind == MessageType.ManagerCallFromSpoke) return "managerCallFromSpoke";
        if (kind == MessageType.AuthorizeSpokeCall) return "authorizeSpokeCall";
        if (kind == MessageType.UnauthorizeSpokeCall) return "unauthorizeSpokeCall";
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
    function _cleanFirstFileInteraction(string memory path) internal {
        uint256 newRunId = vm.envUint("BENCHMARKING_RUN_ID");

        string memory json = vm.readFile(path);
        uint256 fileRunId = _getPreviousRegisteredValue(json, "$.BENCHMARKING_RUN_ID");

        if (fileRunId != newRunId) {
            string[] memory keys = vm.parseJsonKeys(json, "$");
            for (uint256 i; i < keys.length; i++) {
                vm.writeJson("0", path, string.concat("$.", keys[i]));
            }

            vm.writeJson(vm.toString(newRunId), path, "$.BENCHMARKING_RUN_ID");
        }
    }
}
