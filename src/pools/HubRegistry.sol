// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";

import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IHubRegistry} from "src/pools/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

contract HubRegistry is Auth, IHubRegistry {
    using MathLib for uint256;

    uint48 public latestId;

    mapping(AssetId => uint8) internal _decimals;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => AssetId) public currency;
    mapping(bytes32 => address) public dependency;
    mapping(PoolId => mapping(address => bool)) public isAdmin;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IHubRegistry
    function registerAsset(AssetId assetId, uint8 decimals_) external auth {
        require(_decimals[assetId] == 0, AssetAlreadyRegistered());

        _decimals[assetId] = decimals_;

        emit NewAsset(assetId, decimals_);
    }

    /// @inheritdoc IHubRegistry
    function registerPool(address admin_, uint16 centrifugeChainId, AssetId currency_)
        external
        auth
        returns (PoolId poolId)
    {
        require(admin_ != address(0), EmptyAdmin());
        require(!currency_.isNull(), EmptyCurrency());
        require(currency[poolId].isNull(), PoolAlreadyRegistered());

        poolId = newPoolId(centrifugeChainId, ++latestId);

        isAdmin[poolId][admin_] = true;
        currency[poolId] = currency_;

        emit NewPool(poolId, admin_, currency_);
    }

    /// @inheritdoc IHubRegistry
    function updateAdmin(PoolId poolId, address admin_, bool canManage) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(admin_ != address(0), EmptyAdmin());

        isAdmin[poolId][admin_] = canManage;

        emit UpdateAdmin(poolId, admin_, canManage);
    }

    /// @inheritdoc IHubRegistry
    function setMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(exists(poolId), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit SetMetadata(poolId, metadata_);
    }

    /// @inheritdoc IHubRegistry
    function updateDependency(bytes32 what, address dependency_) external auth {
        dependency[what] = dependency_;

        emit UpdateDependency(what, dependency_);
    }

    /// @inheritdoc IHubRegistry
    function updateCurrency(PoolId poolId, AssetId currency_) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(!currency_.isNull(), EmptyCurrency());

        currency[poolId] = currency_;

        emit UpdateCurrency(poolId, currency_);
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
    function exists(PoolId poolId) public view returns (bool) {
        return !currency[poolId].isNull();
    }

    /// @inheritdoc IHubRegistry
    function isRegistered(AssetId assetId) public view returns (bool) {
        return _decimals[assetId] != 0;
    }
}
