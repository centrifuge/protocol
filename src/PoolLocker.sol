// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

/// @dev The inherent contract of `PoolLocker` can not have storage to not break the delegatecall rules
abstract contract PoolLocker {
    error PoolAlreadyUnlocked();
    error WrongExecutionInputs();

    uint64 transient unlocked;

    /// @dev allows to execute a method only if the pool is unlocked.
    /// The method can only be execute as part of `execute()`
    modifier poolUnlocked() {
        require(unlocked != 0);
        _;
    }

    /// @dev returns the unlocked poolId
    function unlockedPoolId() public view returns (uint64) {
        return unlocked;
    }

    /// @dev This method is called first in the multicall execution
    function _unlock(uint64 poolId) internal virtual;

    /// @dev This method is called last in the multical execution
    function _lock() internal virtual;

    /// @dev Performs a generic multicall
    function _multiDelegatecall(address[] calldata targets, bytes[] calldata data) private returns (bytes[] memory results) {
        require(targets.length == data.length, WrongExecutionInputs());

        results = new bytes[](data.length);

        for (uint32 i; i < targets.length; i++) {
            (bool success, bytes memory result) = targets[i].call(data[i]);
            if (!success) {
                // Forward the error happened in target.call()
                assembly {
                    let ptr := mload(0x40)
                    let size := returndatasize()
                    returndatacopy(ptr, 0, size)
                    revert(ptr, size)
                }
            }
            results[i] = result;
        }
    }

    /// @dev Will perform all methods between the unlock <-> lock
    /// All calls with poolUnlocked modifier are able to be called inside this method
    function execute(uint64 poolId, address[] calldata targets, bytes[] calldata data)
        external
        returns (bytes[] memory results)
    {
        require(unlocked == 0, PoolAlreadyUnlocked());
        _unlock(poolId);
        unlocked = poolId;

        results = _multiDelegatecall(targets, data);

        unlocked = 0;
        _lock();
    }
}

