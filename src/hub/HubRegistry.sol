// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";

import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

contract HubRegistry is Auth, IHubRegistry {
    using MathLib for uint256;

    mapping(AssetId => uint8) internal _decimals;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => AssetId) public currency;
    mapping(bytes32 => address) public dependency;
    mapping(PoolId => mapping(address => bool)) public manager;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Registration methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function registerAsset(AssetId assetId, uint8 decimals_) external auth {
        require(_decimals[assetId] == 0, AssetAlreadyRegistered());

        _decimals[assetId] = decimals_;

        emit NewAsset(assetId, decimals_);
    }

    /// @inheritdoc IHubRegistry
    function registerPool(PoolId poolId_, address manager_, AssetId currency_) external auth {
        require(manager_ != address(0), EmptyAccount());
        require(!currency_.isNull(), EmptyCurrency());
        require(currency[poolId_].isNull(), PoolAlreadyRegistered());

        manager[poolId_][manager_] = true;
        currency[poolId_] = currency_;

        emit NewPool(poolId_, manager_, currency_);
    }

    //----------------------------------------------------------------------------------------------
    // Update methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function updateManager(PoolId poolId_, address manager_, bool canManage) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));
        require(manager_ != address(0), EmptyAccount());

        manager[poolId_][manager_] = canManage;

        emit UpdateManager(poolId_, manager_, canManage);
    }

    /// @inheritdoc IHubRegistry
    function setMetadata(PoolId poolId_, bytes calldata metadata_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));

        metadata[poolId_] = metadata_;

        emit SetMetadata(poolId_, metadata_);
    }

    /// @inheritdoc IHubRegistry
    function updateDependency(bytes32 what, address dependency_) external auth {
        dependency[what] = dependency_;

        emit UpdateDependency(what, dependency_);
    }

    /// @inheritdoc IHubRegistry
    function updateCurrency(PoolId poolId_, AssetId currency_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));
        require(!currency_.isNull(), EmptyCurrency());

        currency[poolId_] = currency_;

        emit UpdateCurrency(poolId_, currency_);
    }

    //----------------------------------------------------------------------------------------------
    // PermissViewionless methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function poolId(uint16 centrifugeId, uint48 postfix) public pure returns (PoolId poolId_) {
        poolId_ = newPoolId(centrifugeId, postfix);
    }

    /// @inheritdoc IHubRegistry
    function decimals(AssetId assetId) public view returns (uint8 decimals_) {
        decimals_ = _decimals[assetId];
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IHubRegistry
    function decimals(PoolId poolId) public view returns (uint8 decimals_) {
        decimals_ = _decimals[currency[poolId]];
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IERC6909Decimals
    function decimals(uint256 asset_) external view returns (uint8 decimals_) {
        decimals_ = _decimals[AssetId.wrap(asset_.toUint128())];
        require(decimals_ > 0, AssetNotFound());
    }

    /// @inheritdoc IHubRegistry
    function exists(PoolId poolId_) public view returns (bool) {
        return !currency[poolId_].isNull();
    }

    /// @inheritdoc IHubRegistry
    function isRegistered(AssetId assetId) public view returns (bool) {
        return _decimals[assetId] != 0;
    }
}
