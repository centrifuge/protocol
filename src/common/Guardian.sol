// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IGuardian, ISafe} from "src/common/interfaces/IGuardian.sol";
import {IRootMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

import {IPoolRouter} from "src/pools/interfaces/IPoolRouter.sol";
import {IAssetRegistry} from "src/pools/interfaces/IAssetRegistry.sol";

contract Guardian is IGuardian {
    IRoot public immutable root;

    ISafe public safe;
    IPoolRouter public poolRouter;
    IRootMessageSender public sender;
    IAssetRegistry public assetRegistry;

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

    /// @inheritdoc IGuardian
    function file(bytes32 what, address data) external onlySafe {
        if (what == "safe") safe = ISafe(data);
        else if (what == "sender") sender = IRootMessageSender(data);
        else if (what == "poolRouter") poolRouter = IPoolRouter(data);
        else if (what == "assetRegistry") assetRegistry = IAssetRegistry(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    // --- Admin actions ---
    /// @inheritdoc IGuardian
    function createPool(address admin, AssetId currency, IShareClassManager shareClassManager)
        external
        onlySafe
        returns (PoolId poolId)
    {
        return poolRouter.createPool(admin, currency, shareClassManager);
    }

    /// @inheritdoc IGuardian
    function updateChain(uint16 chainId, string calldata name, string calldata symbol) external onlySafe {
        assetRegistry.updateChain(chainId, name, symbol);
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
    function scheduleUpgrade(uint16 chainId, address target) external onlySafe {
        sender.sendScheduleUpgrade(chainId, bytes32(bytes20(target)));
    }

    /// @inheritdoc IGuardian
    function cancelUpgrade(uint16 chainId, address target) external onlySafe {
        sender.sendCancelUpgrade(chainId, bytes32(bytes20(target)));
    }

    /// @inheritdoc IGuardian
    function initiateMessageRecovery(uint16 chainId, uint16 adapterChainId, IAdapter adapter, bytes32 hash)
        external
        onlySafe
    {
        sender.sendInitiateMessageRecovery(chainId, adapterChainId, bytes32(bytes20(address(adapter))), hash);
    }

    /// @inheritdoc IGuardian
    function disputeMessageRecovery(uint16 chainId, uint16 adapterChainId, IAdapter adapter, bytes32 hash)
        external
        onlySafe
    {
        sender.sendDisputeMessageRecovery(chainId, adapterChainId, bytes32(bytes20(address(adapter))), hash);
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
