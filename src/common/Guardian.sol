// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {AssetId} from "./types/AssetId.sol";
import {IRoot} from "./interfaces/IRoot.sol";
import {IAdapter} from "./interfaces/IAdapter.sol";
import {IGateway} from "./interfaces/IGateway.sol";
import {IGuardian, ISafe} from "./interfaces/IGuardian.sol";
import {IMultiAdapter} from "./interfaces/IMultiAdapter.sol";
import {IRootMessageSender} from "./interfaces/IGatewaySenders.sol";
import {IHubGuardianActions} from "./interfaces/IGuardianActions.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";

contract Guardian is IGuardian {
    using CastLib for address;

    IRoot public immutable root;

    ISafe public safe;
    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    IHubGuardianActions public hub;
    IRootMessageSender public sender;

    constructor(
        ISafe safe_,
        IRoot root_,
        IGateway gateway_,
        IMultiAdapter multiAdapter_,
        IRootMessageSender messageDispatcher_
    ) {
        safe = safe_;
        root = root_;
        gateway = gateway_;
        multiAdapter = multiAdapter_;
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
        else if (what == "hub") hub = IHubGuardianActions(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
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
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external
        onlySafe
    {
        multiAdapter.setAdapters(centrifugeId, PoolId.wrap(0), adapters, threshold, recoveryIndex);
    }

    /// @inheritdoc IGuardian
    function updateGatewayManager(address who, bool canManage) external onlySafe {
        gateway.updateManager(PoolId.wrap(0), who, canManage);
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
