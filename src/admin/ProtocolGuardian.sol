// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "./interfaces/IRoot.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IProtocolGuardian} from "./interfaces/IProtocolGuardian.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";

import {IScheduleAuthMessageSender} from "../core/messaging/interfaces/IGatewaySenders.sol";

import {ITokenBridge} from "../bridge/interfaces/ITokenBridge.sol";

/// @title  ProtocolGuardian
/// @notice This contract provides emergency controls and protocol-level management including pausing,
///         permission scheduling, and cross-chain upgrade coordination.
contract ProtocolGuardian is IProtocolGuardian {
    using CastLib for address;

    IRoot public immutable root;
    ISafe public safe;
    ITokenBridge public tokenBridge;
    IScheduleAuthMessageSender public sender;

    constructor(ISafe safe_, IRoot root_, IScheduleAuthMessageSender sender_, ITokenBridge tokenBridge_) {
        safe = safe_;
        root = root_;
        sender = sender_;
        tokenBridge = tokenBridge_;
    }

    modifier onlySafe() {
        require(msg.sender == address(safe), NotTheAuthorizedSafe());
        _;
    }

    modifier onlySafeOrOwner() {
        require(msg.sender == address(safe) || _isSafeOwner(msg.sender), NotTheAuthorizedSafeOrItsOwner());
        _;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "sender") sender = IScheduleAuthMessageSender(data);
        else if (what == "tokenBridge") tokenBridge = ITokenBridge(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Emergency Functions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function pause() external onlySafeOrOwner {
        root.pause();
    }

    /// @inheritdoc IProtocolGuardian
    function unpause() external onlySafe {
        root.unpause();
    }

    //----------------------------------------------------------------------------------------------
    // Permission Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function scheduleRely(address target) external onlySafe {
        root.scheduleRely(target);
    }

    /// @inheritdoc IProtocolGuardian
    function cancelRely(address target) external onlySafe {
        root.cancelRely(target);
    }

    //----------------------------------------------------------------------------------------------
    // Bridge Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function fileTokenBridgeRelayer(address relayer) external onlySafe {
        tokenBridge.file("relayer", relayer);
    }

    //----------------------------------------------------------------------------------------------
    // Cross-Chain Operations
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function scheduleUpgrade(uint16 centrifugeId, address target, address refund) external payable onlySafe {
        sender.sendScheduleUpgrade{value: msg.value}(centrifugeId, target.toBytes32(), refund);
    }

    /// @inheritdoc IProtocolGuardian
    function cancelUpgrade(uint16 centrifugeId, address target, address refund) external payable onlySafe {
        sender.sendCancelUpgrade{value: msg.value}(centrifugeId, target.toBytes32(), refund);
    }

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    function _isSafeOwner(address addr) internal view returns (bool) {
        try safe.isOwner(addr) returns (bool isOwner) {
            return isOwner;
        } catch {
            return false;
        }
    }
}
