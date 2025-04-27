// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGuardian, ISafe} from "src/common/interfaces/IGuardian.sol";
import {IRootMessageSender} from "src/common/interfaces/IGatewaySenders.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";

contract Guardian is IGuardian {
    using CastLib for address;

    IRoot public immutable root;

    IHub public hub;
    ISafe public safe;
    IRootMessageSender public sender;

    constructor(ISafe safe_, IRoot root_, IRootMessageSender messageDispatcher_) {
        root = root_;
        safe = safe_;
        sender = messageDispatcher_;
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

    /// @inheritdoc IGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "sender") sender = IRootMessageSender(data);
        else if (what == "hub") hub = IHub(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Admin actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IGuardian
    function createPool(PoolId poolId, address admin, AssetId currency) external onlySafe {
        return hub.createPool(poolId, admin, currency);
    }

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
    function scheduleUpgrade(uint16 centrifugeId, address target) external onlySafe {
        sender.sendScheduleUpgrade(centrifugeId, target.toBytes32());
    }

    /// @inheritdoc IGuardian
    function cancelUpgrade(uint16 centrifugeId, address target) external onlySafe {
        sender.sendCancelUpgrade(centrifugeId, target.toBytes32());
    }

    /// @inheritdoc IGuardian
    function recoverTokens(
        uint16 centrifugeId,
        address target,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount
    ) external onlySafe {
        sender.sendRecoverTokens(centrifugeId, target.toBytes32(), token.toBytes32(), tokenId, to.toBytes32(), amount);
    }

    /// @inheritdoc IGuardian
    function initiateRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, IAdapter adapter, bytes32 hash)
        external
        onlySafe
    {
        sender.sendInitiateRecovery(centrifugeId, adapterCentrifugeId, address(adapter).toBytes32(), hash);
    }

    /// @inheritdoc IGuardian
    function disputeRecovery(uint16 centrifugeId, uint16 adapterCentrifugeId, IAdapter adapter, bytes32 hash)
        external
        onlySafe
    {
        sender.sendDisputeRecovery(centrifugeId, adapterCentrifugeId, address(adapter).toBytes32(), hash);
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
