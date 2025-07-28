// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGuardian, ISafe} from "src/common/interfaces/IGuardian.sol";
import {IRootMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IHubGuardianActions} from "src/common/interfaces/IGuardianActions.sol";
import {IMultiAdapter} from "src/common/interfaces/adapters/IMultiAdapter.sol";
import {IAxelarAdapter} from "src/common/interfaces/adapters/IAxelarAdapter.sol";
import {IWormholeAdapter} from "src/common/interfaces/adapters/IWormholeAdapter.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";

contract Guardian is IGuardian {
    using CastLib for address;

    IRoot public immutable root;

    ISafe public safe;
    IMultiAdapter public multiAdapter;
    IHubGuardianActions public hub;
    IRootMessageSender public sender;

    constructor(ISafe safe_, IMultiAdapter multiAdapter_, IRoot root_, IRootMessageSender messageDispatcher_) {
        root = root_;
        multiAdapter = multiAdapter_;
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
        else if (what == "hub") hub = IHubGuardianActions(data);
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
    function initiateRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 hash) external onlySafe {
        multiAdapter.initiateRecovery(centrifugeId, adapter, hash);
    }

    /// @inheritdoc IGuardian
    function disputeRecovery(uint16 centrifugeId, IAdapter adapter, bytes32 hash) external onlySafe {
        multiAdapter.disputeRecovery(centrifugeId, adapter, hash);
    }

    /// @inheritdoc IGuardian
    function wireAdapters(uint16 centrifugeId, IAdapter[] calldata adapters) external onlySafe {
        multiAdapter.file("adapters", centrifugeId, adapters);
    }

    /// @inheritdoc IGuardian
    function wireWormholeAdapter(IWormholeAdapter localAdapter, uint16 centrifugeId, uint16 wormholeId, address adapter)
        external
        onlySafe
    {
        localAdapter.file("sources", centrifugeId, wormholeId, adapter);
        localAdapter.file("destinations", centrifugeId, wormholeId, adapter);
    }

    /// @inheritdoc IGuardian
    function wireAxelarAdapter(
        IAxelarAdapter localAdapter,
        uint16 centrifugeId,
        string calldata axelarId,
        string calldata adapter
    ) external onlySafe {
        localAdapter.file("sources", axelarId, centrifugeId, adapter);
        localAdapter.file("destinations", centrifugeId, axelarId, adapter);
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
