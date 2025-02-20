// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root} from "src/vaults/Root.sol";
import {IGuardian} from "src/vaults/interfaces/IGuardian.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";

interface ISafe {
    function isOwner(address signer) external view returns (bool);
}

contract Guardian is IGuardian {
    Root public immutable root;
    ISafe public immutable safe;
    IGateway public immutable gateway;

    constructor(address safe_, address root_, address gateway_) {
        root = Root(root_);
        safe = ISafe(safe_);
        gateway = IGateway(gateway_);
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), "Guardian/not-the-authorized-safe");
        _;
    }

    modifier onlySafeOrOwner() {
        require(
            msg.sender == address(safe) || _isSafeOwner(msg.sender), "Guardian/not-the-authorized-safe-or-its-owner"
        );
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
