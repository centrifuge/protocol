// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {D18} from "src/types/D18.sol";
import {PoolLocker} from "src/PoolLocker.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";

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
    function requestDeposit(uint64 poolId, uint32 shareClassId, uint256 assetId, address investor, uint128 amount)
        external;
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

interface IAssetManager is IERC6909 {}

interface IAccounting {
    function unlock(uint64 poolId) external;
    function lock(uint64 poolId) external;
}

interface IHoldings {
    function updateHoldings() external;
}

interface IGateway {
    function send(bytes calldata message) external;
}

contract PoolManager is PoolLocker {
    IPoolRegistry immutable poolRegistry;
    IAssetManager immutable assetManager;
    IAccounting immutable accounting;

    IHoldings immutable holdings;
    IGateway immutable gateway;

    constructor(
        IPoolRegistry poolRegistry_,
        IAssetManager assetManager_,
        IAccounting accounting_,
        IHoldings holdings_,
        IGateway gateway_
    ) {
        poolRegistry = poolRegistry_;
        assetManager = assetManager_;
        accounting = accounting_;
        holdings = holdings_;
        gateway = gateway_;
    }

    /// @dev This method is called first in a multicall
    function _unlock(uint64 poolId) internal override {
        require(poolRegistry.isUnlocker(msg.sender, poolId));
        accounting.unlock(poolId);
    }

    /// @dev This method is called last in `execute()`
    function _lock() internal override {
        accounting.lock(_unlockedPoolId());
    }

    function registerPool() external returns (uint64) {
        // TODO: calculate fees
        return poolRegistry.registerPool(msg.sender);
    }

    function handle(bytes calldata message) external {
        require(msg.sender == address(gateway));
        // TODO decode
        // TODO: Call to specific method of this contract, i.e depositRequest
    }

    function allowPool(uint32 chainId) external poolUnlocked {}
    function allowShareClass(uint32 chainId) external poolUnlocked {}

    function depositRequest(uint32 shareClassId, uint256 assetId, address investor, uint128 amount)
        private
        poolUnlocked
    {
        uint64 poolId = _unlockedPoolId();
        poolRegistry.shareClassManager(poolId).requestDeposit(poolId, shareClassId, assetId, investor, amount);
    }

    function approveSubscription(uint64 poolId) external poolUnlocked {}
    function updateHoldings() external poolUnlocked {}
    function issueShares(uint64 poolId) external poolUnlocked {}
    function claimShares(uint64 poolId) external {}
}
