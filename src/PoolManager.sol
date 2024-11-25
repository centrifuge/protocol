// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";

contract PoolRegistry is Auth {
    constructor(address owner) Auth(owner) {}

    // Can also be called isFundManager or be extracted in a Permissions contract
    // NOTE: The gateway contract is able to unlock any poolId
    function isUnlocker(address who, uint64 poolId) auth public view returns (bool) {}

    // Associate who to be the owner/poolAdmin of the new poolId
    function registerPool(address who) auth public returns (uint64) {}
}

contract PoolManager is Auth {
    PoolRegistry poolRegistry;
    uint64 transient unlockedPool;

    constructor(address owner) Auth(owner) {
        poolRegistry = PoolRegistry(address(this));
    }

    modifier poolUnlocked() {
        require(unlockedPool != 0);
        _;
    }

    // This method is called first in a multicall
    function unlock(uint64 poolId) external {
        require(poolRegistry.isUnlocker(msg.sender, poolId));
        unlockedPool = poolId;
    }

    // In case the fundManager wants to lock in the same multicall to do other actions
    function lock() external {
        require(poolRegistry.isUnlocker(msg.sender, unlockedPool));
        unlockedPool = 0;
    }

    // ---- Calls that require to unlock ----

    function allowPool(uint32 chainId) external poolUnlocked() {}
    function allowShareClass(uint32 chainId) external poolUnlocked() {}

    function depositRequest() external poolUnlocked() {
        // Retriver the unlocked poolId to use it internally
        shareClassManager.depositRequest(unlockedPool, ..);
    }
    function approveSubscription(uint64 poolId) external poolUnlocked() {}
    function issueShares(uint64 poolId) external poolUnlocked() {}

    // ---- Permissionless calls ----

    function registerPool() external returns (uint64) {
        // Dispatch some event associated to PoolManager
        return poolRegistry.registerPool(msg.sender);
    }

    function claimDistribute(uint64 poolId) external {}
}
