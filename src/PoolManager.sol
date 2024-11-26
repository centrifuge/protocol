// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {D18} from "src/types/D18.sol";

/// [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle
/// Interface for data feeds providing the relative value of assets.
interface IERC7726 {
    /// @notice Returns the value of `baseAmount` of `base` in quote `terms`.
    /// It's rounded towards 0 and reverts if overflow
    /// @param base The asset that the user needs to know the value for
    /// @param quote The asset in which the user needs to value the base
    /// @param baseAmount An amount of base in quote terms
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

interface IShareClassManager {
    function requestDeposit(uint64 poolId, uint32 shareClassId, uint256 assetId, address investor) external;
    function approveSubscription(
        uint64 poolId,
        uint32 shareClassId,
        uint256 assetId,
        D18 percentage,
        IERC7726 valuation
    ) external;
    function issueShares(uint64 poolId, uint32 shareClassId, uint128 nav, uint64 epochIndex) external;
    function claimShares(uint64 poolId, uint32 shareClassId, uint256 assetId, address investor) external;
}

interface IPoolRegistry {
    // Can also be called "isFundManager" or be extracted in a Permissions contract
    // NOTE: The gateway contract is able to unlock any poolId
    function isUnlocker(address who, uint64 poolId) external view returns (bool);

    // Associate who to be the owner/poolAdmin of the new poolId
    function registerPool(address who) external returns (uint64);

    function shareClassManager(uint64 poolId) external view returns (IShareClassManager);
}

interface IAccounting {
    function unlock(uint64 poolId) external;
    function lock(uint64 poolId) external;
}

contract PoolManager is Auth {
    error WrongExecutionInputs();
    error FailedCallExecution(uint32 callIndex);

    IPoolRegistry poolRegistry;
    IAccounting accounting;

    uint64 unlockedPool; // Transient

    constructor(address owner) Auth(owner) {}

    modifier poolUnlocked() {
        require(unlockedPool != 0);
        _;
    }

    // This method is called first in a multicall
    function _unlock(uint64 poolId) private {
        require(poolRegistry.isUnlocker(msg.sender, poolId));
        unlockedPool = poolId;
        accounting.unlock(poolId);
    }

    function _lock() private {
        accounting.unlock(unlockedPool);
        unlockedPool = 0;
    }

    /// @dev Will perform all methods between the unlock <-> lock
    /// @dev All calls with poolUnlocked modifier are able to be called inside this method
    function execute(uint64 poolId, address[] calldata targets, bytes[] calldata data)
        external
        returns (bytes[] memory results)
    {
        _unlock(poolId);

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

        _lock();
    }

    // ---- Calls that require to unlock ----

    function allowPool(uint32 chainId) public poolUnlocked {}
    function allowShareClass(uint32 chainId) public poolUnlocked {}

    function depositRequest(uint32 shareClassId, uint256 assetId, address investor) public poolUnlocked {
        poolRegistry.shareClassManager(unlockedPool).requestDeposit(unlockedPool, shareClassId, assetId, investor);
    }

    function approveSubscription(uint64 poolId) public poolUnlocked {}
    function issueShares(uint64 poolId) public poolUnlocked {}

    // ---- Permissionless calls ----

    function registerPool() external returns (uint64) {
        // Dispatch some event associated to PoolManager
        return poolRegistry.registerPool(msg.sender);
    }

    function claimShares(uint64 poolId) public {}
}
