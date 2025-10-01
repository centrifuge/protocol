// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IProtocolGuardian} from "./interfaces/IProtocolGuardian.sol";
import {IRootMessageSender} from "./interfaces/IGatewaySenders.sol";
import {IHubGuardianActions} from "./interfaces/IGuardianActions.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

contract ProtocolGuardian is IProtocolGuardian {
    using CastLib for address;

    IRoot public immutable root;
    ISafe public safe;
    IHubGuardianActions public hub;
    IRootMessageSender public sender;

    constructor(ISafe safe_, IRoot root_, IRootMessageSender sender_) {
        safe = safe_;
        root = root_;
        sender = sender_;
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

    /// @inheritdoc IProtocolGuardian
    function recoverTokens(
        uint16 centrifugeId,
        address target,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount,
        address refund
    ) external payable onlySafe {
        sender.sendRecoverTokens{value: msg.value}(
            centrifugeId, target.toBytes32(), token.toBytes32(), tokenId, to.toBytes32(), amount, refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // Pool Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        hub.createPool(poolId, admin, currency);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "hub") hub = IHubGuardianActions(data);
        else if (what == "sender") sender = IRootMessageSender(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
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
