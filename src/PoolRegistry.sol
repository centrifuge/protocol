// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {PoolId} from "src/types/PoolId.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    uint32 public latestId;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => IERC20Metadata) public poolCurrencies;
    mapping(PoolId => IShareClassManager) public shareClassManagers;
    mapping(PoolId => mapping(address => bool)) public poolAdmins;
    mapping(PoolId => mapping(bytes32 key => address)) public addresses;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(address admin, IERC20Metadata currency_, IShareClassManager shareClassManager_)
        external
        auth
        returns (PoolId poolId)
    {
        require(admin != address(0), EmptyAdmin());
        require(address(currency_) != address(0), EmptyCurrency());
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

        // TODO: Make this part of the library. Something like PoolId.generate();
        poolId = PoolId.wrap((uint64(block.chainid.toUint32()) << 32) | uint64(++latestId));

        poolAdmins[poolId][admin] = true;
        poolCurrencies[poolId] = currency_;
        shareClassManagers[poolId] = shareClassManager_;

        emit NewPool(poolId, admin, shareClassManager_, currency_);
    }

    /// @inheritdoc IPoolRegistry
    function updateAdmin(PoolId poolId, address admin, bool canManage) external auth {
        require(admin != address(0), EmptyAdmin());
        require(address(shareClassManagers[poolId]) != address(0), NonExistingPool(poolId));

        poolAdmins[poolId][admin] = canManage;

        emit UpdatedPoolAdmin(poolId, admin);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(address(shareClassManagers[poolId]) != address(0), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit UpdatedPoolMetadata(poolId, metadata_);
    }

    /// @inheritdoc IPoolRegistry
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager_) external auth {
        require(address(shareClassManagers[poolId]) != address(0), NonExistingPool(poolId));
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

        shareClassManagers[poolId] = shareClassManager_;

        emit UpdatedShareClassManager(poolId, shareClassManager_);
    }

    /// @inheritdoc IPoolRegistry
    function updateCurrency(PoolId poolId, IERC20Metadata currency_) external auth {
        require(address(shareClassManagers[poolId]) != address(0), NonExistingPool(poolId));
        require(address(currency_) != address(0), EmptyCurrency());

        poolCurrencies[poolId] = currency_;

        emit UpdatedPoolCurrency(poolId, currency_);
    }

    /// @inheritdoc IPoolRegistry
    function setAddressFor(PoolId poolId, bytes32 key, address value) external auth {
        addresses[poolId][key] = value;
    }

    /// @inheritdoc IPoolRegistry
    function currency(PoolId poolId) external view returns (IERC20Metadata) {
        return poolCurrencies[poolId];
    }

    /// @inheritdoc IPoolRegistry
    function isAdmin(PoolId poolId, address admin) external view returns (bool) {
        return poolAdmins[poolId][admin];
    }

    /// @inheritdoc IPoolRegistry
    function shareClassManager(PoolId poolId) external view returns (IShareClassManager) {
        return shareClassManagers[poolId];
    }

    /// @inheritdoc IPoolRegistry
    function addressFor(PoolId poolId, bytes32 key) external view returns (address) {
        return addresses[poolId][key];
    }
}
