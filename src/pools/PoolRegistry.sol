// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {PoolId, newPoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    uint32 public latestId;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => AssetId) public currency;
    mapping(PoolId => IShareClassManager) public shareClassManager;
    mapping(PoolId => mapping(address => bool)) public isAdmin;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(address admin_, AssetId currency_, IShareClassManager shareClassManager_)
        external
        auth
        returns (PoolId poolId)
    {
        require(admin_ != address(0), EmptyAdmin());
        require(!currency_.isNull(), EmptyCurrency());
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

        poolId = newPoolId(++latestId);

        isAdmin[poolId][admin_] = true;
        currency[poolId] = currency_;
        shareClassManager[poolId] = shareClassManager_;

        emit NewPool(poolId, admin_, shareClassManager_, currency_);
    }

    /// @inheritdoc IPoolRegistry
    function updateAdmin(PoolId poolId, address admin_, bool canManage) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(admin_ != address(0), EmptyAdmin());

        isAdmin[poolId][admin_] = canManage;

        emit UpdatedAdmin(poolId, admin_, canManage);
    }

    /// @inheritdoc IPoolRegistry
    function setMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(exists(poolId), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit SetMetadata(poolId, metadata_);
    }

    /// @inheritdoc IPoolRegistry
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager_) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

        shareClassManager[poolId] = shareClassManager_;

        emit UpdatedShareClassManager(poolId, shareClassManager_);
    }

    /// @inheritdoc IPoolRegistry
    function updateCurrency(PoolId poolId, AssetId currency_) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(!currency_.isNull(), EmptyCurrency());

        currency[poolId] = currency_;

        emit UpdatedCurrency(poolId, currency_);
    }

    function exists(PoolId poolId) public view returns (bool) {
        return address(shareClassManager[poolId]) != address(0);
    }
}
