// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "./interfaces/IRoot.sol";
import {ISafe} from "./interfaces/ISafe.sol";
import {IBaseGuardian} from "./interfaces/IBaseGuardian.sol";
import {IAdapterWiring} from "./interfaces/IAdapterWiring.sol";
import {IProtocolGuardian} from "./interfaces/IProtocolGuardian.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {IAdapter} from "../core/interfaces/IAdapter.sol";
import {IGateway} from "../core/interfaces/IGateway.sol";
import {IMultiAdapter} from "../core/interfaces/IMultiAdapter.sol";
import {IScheduleAuthMessageSender} from "../core/interfaces/IGatewaySenders.sol";

/// @title  ProtocolGuardian
/// @notice This contract provides emergency controls and protocol-level management including pausing,
///         permission scheduling, cross-chain upgrade coordination, and adapter configuration.
contract ProtocolGuardian is IProtocolGuardian {
    using CastLib for address;

    PoolId public constant GLOBAL_POOL = PoolId.wrap(0);

    IRoot public immutable root;
    ISafe public safe;
    IGateway public gateway;
    IMultiAdapter public multiAdapter;
    IScheduleAuthMessageSender public sender;

    constructor(
        ISafe safe_,
        IRoot root_,
        IGateway gateway_,
        IMultiAdapter multiAdapter_,
        IScheduleAuthMessageSender sender_
    ) {
        safe = safe_;
        root = root_;
        gateway = gateway_;
        multiAdapter = multiAdapter_;
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
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IBaseGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "gateway") gateway = IGateway(data);
        else if (what == "multiAdapter") multiAdapter = IMultiAdapter(data);
        else if (what == "sender") sender = IScheduleAuthMessageSender(data);
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
    // Adapter Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IProtocolGuardian
    function setAdapters(uint16 centrifugeId, IAdapter[] calldata adapters, uint8 threshold, uint8 recoveryIndex)
        external
        onlySafe
    {
        multiAdapter.setAdapters(centrifugeId, GLOBAL_POOL, adapters, threshold, recoveryIndex);
    }

    /// @inheritdoc IProtocolGuardian
    function blockOutgoing(uint16 centrifugeId, bool isBlocked) external onlySafe {
        gateway.blockOutgoing(centrifugeId, GLOBAL_POOL, isBlocked);
    }

    /// @inheritdoc IBaseGuardian
    function wire(address adapter, uint16 centrifugeId, bytes memory data) external onlySafe {
        IAdapterWiring(adapter).wire(centrifugeId, data);
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
