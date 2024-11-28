// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";

/// @notice Abstract the mechanism to unlocks pools
abstract contract PoolLocker is IPoolLocker {
    /// @dev Represents the unlocked pool Id
    uint64 private transient unlocked;

    /// @dev allows to execute a method only if the pool is unlocked.
    /// The method can only be execute as part of `execute()`
    modifier poolUnlocked() {
        require(unlocked != 0);
        _;
    }

    /// @inheritdoc IPoolLocker
    function unlockedPoolId() public view returns (uint64) {
        return unlocked;
    }

    /// @dev This method is called first in the multicall execution
    function _unlock(uint64 poolId) internal virtual;

    /// @dev This method is called last in the multical execution
    function _lock() internal virtual;

    /// @dev Performs a generic multicall. It reverts the whole transaction if one call fails.
    function _multiCall(address[] calldata targets, bytes[] calldata datas) private returns (bytes[] memory results) {
        require(targets.length == datas.length, WrongExecutionParams());

        results = new bytes[](datas.length);

        for (uint32 i; i < targets.length; i++) {
            (bool success, bytes memory result) = targets[i].call(datas[i]);
            if (!success) {
                // Forward the error happened in target.call().
                if (!success) {
                    assembly {
                        let ptr := mload(0x40)
                        let size := returndatasize()
                        returndatacopy(ptr, 0, size)
                        revert(ptr, size)
                    }
                }
            }
            results[i] = result;
        }
    }

    /// @inheritdoc IPoolLocker
    /// @dev All calls with `poolUnlocked` modifier are able to be called inside this method
    function execute(uint64 poolId, address[] calldata targets, bytes[] calldata datas)
        external
        returns (bytes[] memory results)
    {
        require(unlocked == 0, PoolAlreadyUnlocked());
        _unlock(poolId);
        unlocked = poolId;

        results = _multiCall(targets, datas);

        unlocked = 0;
        _lock();
    }
}

