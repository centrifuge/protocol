// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    uint32 public latestId;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => mapping(address => bool)) public poolAdmins;
    mapping(PoolId => address) public shareClassManagers;
    mapping(PoolId => address) public itemManagers;
    mapping(PoolId => Currency) public poolCurrencies;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(address admin, Currency currency, address shareClassManager)
        external
        auth
        returns (PoolId poolId)
    {
        require(admin != address(0), EmptyAdmin());
        require(Currency.unwrap(currency) != address(0), EmptyCurrency());
        require(shareClassManager != address(0), EmptyShareClassManager());

        // TODO: Make this part of the library. Something like PoolId.generate();
        poolId = PoolId.wrap((uint64(block.chainid.toUint32()) << 32) | uint64(++latestId));

        poolAdmins[poolId][admin] = true;
        poolCurrencies[poolId] = currency;
        shareClassManagers[poolId] = shareClassManager;

        emit NewPool(poolId, admin, shareClassManager, currency);
    }

    /// @inheritdoc IPoolRegistry
    function updateAdmin(PoolId poolId, address admin, bool canManage) external auth {
        require(admin != address(0), EmptyAdmin());
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));

        poolAdmins[poolId][admin] = canManage;

        emit NewPoolManager(poolId, admin);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit NewPoolMetadata(poolId, metadata_);
    }

    /// @inheritdoc IPoolRegistry
    function updateShareClassManager(PoolId poolId, address shareClassManager) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));
        require(shareClassManager != address(0), EmptyShareClassManager());

        shareClassManagers[poolId] = shareClassManager;

        emit NewShareClassManager(poolId, shareClassManager);
    }

    /// @inheritdoc IPoolRegistry
    function updateItemManager(PoolId poolId, address itemManager) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));
        require(itemManager != address(0), EmptyItemManager());

        itemManagers[poolId] = itemManager;

        emit NewItemManager(poolId, itemManager);
    }

    /// @inheritdoc IPoolRegistry
    function updateCurrency(PoolId poolId, Currency currency) external auth {
        require(shareClassManagers[poolId] != address(0), NonExistingPool(poolId));
        require(Currency.unwrap(currency) != address(0), EmptyCurrency());

        poolCurrencies[poolId] = currency;

        emit NewPoolCurrency(poolId, currency);
    }
}
