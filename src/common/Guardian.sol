// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IGuardian, ISafe} from "src/common/interfaces/IGuardian.sol";
import {IRootMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

contract Guardian is IGuardian {
    IRoot public immutable root;
    ISafe public immutable safe;

    IRootMessageSender public messageDispatcher;

    constructor(ISafe safe_, IRoot root_, IRootMessageSender messageDispatcher_) {
        root = root_;
        safe = safe_;
        messageDispatcher = messageDispatcher_;
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), NotTheAuthorizedSafe());
        _;
    }

    modifier onlySafeOrOwner() {
        require(msg.sender == address(safe) || _isSafeOwner(msg.sender), NotTheAuthorizedSafeOrItsOwner());
        _;
    }

    // TODO: add file method for messageDispatcher

    // --- Admin actions ---
    /// @inheritdoc IGuardian
    function pause() external onlySafeOrOwner {
        root.pause();
    }

    /// @inheritdoc IGuardian
    function unpause() external onlySafe {
        root.unpause();
    }

    /// @inheritdoc IGuardian
    function scheduleRely(address target) external onlySafe {
        root.scheduleRely(target);
    }

    /// @inheritdoc IGuardian
    function cancelRely(address target) external onlySafe {
        root.cancelRely(target);
    }

    /// @inheritdoc IGuardian
    function scheduleUpgrade(uint16 chainId, address target) external onlySafe {
        messageDispatcher.sendScheduleUpgrade(chainId, bytes32(bytes20(target)));
    }

    /// @inheritdoc IGuardian
    function cancelUpgrade(uint16 chainId, address target) external onlySafe {
        messageDispatcher.sendCancelUpgrade(chainId, bytes32(bytes20(target)));
    }

    /// @inheritdoc IGuardian
    function initiateMessageRecovery(uint16 chainId, bytes32 hash, IAdapter adapter) external onlySafe {
        messageDispatcher.sendInitiateMessageRecovery(chainId, hash, bytes32(bytes20(address(adapter))));
    }

    /// @inheritdoc IGuardian
    function disputeMessageRecovery(uint16 chainId, bytes32 hash, IAdapter adapter) external onlySafe {
        messageDispatcher.sendDisputeMessageRecovery(chainId, hash, bytes32(bytes20(address(adapter))));
    }

    // --- Helpers ---
    function _isSafeOwner(address addr) internal view returns (bool) {
        try safe.isOwner(addr) returns (bool isOwner) {
            return isOwner;
        } catch {
            return false;
        }
    }
}
