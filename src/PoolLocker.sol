// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "src/types/Domain.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

abstract contract PoolLocker is IPoolLocker {
    /// Contract for the multicall
    IMulticall private immutable multicall;

    /// @dev Represents the unlocked pool Id
    PoolId private /*TODO: transient*/ unlocked;

    /// @dev allows to execute a method only if the pool is unlocked.
    /// The method can only be execute as part of `execute()`
    modifier poolUnlocked() {
        require(PoolId.unwrap(unlocked) != 0, PoolLocked());
        _;
    }

    constructor(IMulticall multicall_) {
        multicall = multicall_;
    }

    /// @inheritdoc IPoolLocker
    /// @dev All calls with `poolUnlocked` modifier are able to be called inside this method
    function execute(PoolId poolId, address[] calldata targets, bytes[] calldata datas)
        external
        returns (bytes[] memory results)
    {
        require(PoolId.unwrap(unlocked) == 0, PoolAlreadyUnlocked());
        _beforeUnlock(poolId);
        unlocked = poolId;

        results = multicall.aggregate(targets, datas);

        unlocked = PoolId.wrap(0);
        _afterLock();
    }

    /// @inheritdoc IPoolLocker
    function unlockedPoolId() public view returns (PoolId) {
        return unlocked;
    }

    /// @dev This method is called first in the multicall execution
    function _beforeUnlock(PoolId poolId) internal virtual;

    /// @dev This method is called last in the multical execution
    function _afterLock() internal virtual;
}
