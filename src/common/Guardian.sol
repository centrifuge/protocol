// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IGuardian, ISafe} from "src/common/interfaces/IGuardian.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";

contract Guardian is IGuardian {
    IRoot public immutable root;
    ISafe public immutable safe;
    IGateway public immutable gateway;

    constructor(ISafe safe_, IRoot root_, IGateway gateway_) {
        root = root_;
        safe = safe_;
        gateway = gateway_;
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), NotTheAuthorizedSafe());
        _;
    }

    modifier onlySafeOrOwner() {
        require(msg.sender == address(safe) || _isSafeOwner(msg.sender), NotTheAuthorizedSafeOrItsOwner());
        _;
    }

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
    function disputeMessageRecovery(address adapter, bytes32 messageHash) external onlySafe {
        gateway.disputeMessageRecovery(adapter, messageHash);
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
