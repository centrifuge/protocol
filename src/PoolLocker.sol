// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {IPoolLocker} from "src/interfaces/IPoolLocker.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";

abstract contract PoolLocker is IPoolLocker {
    /// Contract for the multicall
    IMulticall private immutable defaultMulticall;

    /// @dev Represents the unlocked pool Id
    PoolId private /*TODO: transient*/ _unlockedPoolId;

    /// @dev allows to execute a method only if the pool is unlocked.
    /// The method can only be execute as part of `execute()`
    modifier poolUnlocked() {
        require(PoolId.unwrap(_unlockedPoolId) != 0, PoolLocked());
        _;
    }

    constructor(IMulticall multicall_) {
        defaultMulticall = multicall_;
    }

    /// @inheritdoc IPoolLocker
    /// @dev All calls with `poolUnlocked` modifier are able to be called inside this method
    function execute(PoolId poolId, IMulticall.Call[] calldata calls) external returns (bytes[] memory results) {
        require(PoolId.unwrap(_unlockedPoolId) == 0, PoolAlreadyUnlocked());

        IMulticall multicallEscrow = _beforeUnlock(poolId);
        _unlockedPoolId = poolId;

        IMulticall multicall = address(multicallEscrow) != address(0) ? multicallEscrow : defaultMulticall;

        results = multicall.aggregate(calls);

        _beforeLock();
        _unlockedPoolId = PoolId.wrap(0);
    }

    /// @inheritdoc IPoolLocker
    function unlockedPoolId() public view returns (PoolId) {
        return _unlockedPoolId;
    }

    /// @dev This method is called first in the multicall execution
    function _beforeUnlock(PoolId poolId) internal virtual returns (IMulticall);

    /// @dev This method is called last in the multicall execution
    function _beforeLock() internal virtual;
}
