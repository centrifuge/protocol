// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {PoolId, PoolIdLib} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

contract PoolRegistry is Auth, IPoolRegistry {
    using MathLib for uint256;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => IERC20Metadata) public currency;
    mapping(PoolId => IShareClassManager) public shareClassManager;
    mapping(PoolId => mapping(address => bool)) public isAdmin;
    mapping(PoolId => mapping(AssetId => bool)) public isInvestorAsset;
    mapping(PoolId => mapping(bytes32 key => address)) public addressFor;

    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IPoolRegistry
    function registerPool(
        uint32 localPoolId,
        address admin_,
        IERC20Metadata currency_,
        IShareClassManager shareClassManager_
    ) external auth returns (PoolId poolId) {
        poolId = PoolIdLib.newFrom(localPoolId);

        require(!exists(poolId), PoolAlreadyExists());
        require(admin_ != address(0), EmptyAdmin());
        require(address(currency_) != address(0), EmptyCurrency());
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

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
    function allowInvestorAsset(PoolId poolId, AssetId assetId, bool isAllowed) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(!assetId.isNull(), EmptyAsset());

        isInvestorAsset[poolId][assetId] = isAllowed;

        emit AllowedInvestorAsset(poolId, assetId, isAllowed);
    }

    /// @inheritdoc IPoolRegistry
    function updateMetadata(PoolId poolId, bytes calldata metadata_) external auth {
        require(exists(poolId), NonExistingPool(poolId));

        metadata[poolId] = metadata_;

        emit UpdatedMetadata(poolId, metadata_);
    }

    /// @inheritdoc IPoolRegistry
    function updateShareClassManager(PoolId poolId, IShareClassManager shareClassManager_) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(address(shareClassManager_) != address(0), EmptyShareClassManager());

        shareClassManager[poolId] = shareClassManager_;

        emit UpdatedShareClassManager(poolId, shareClassManager_);
    }

    /// @inheritdoc IPoolRegistry
    function updateCurrency(PoolId poolId, IERC20Metadata currency_) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        require(address(currency_) != address(0), EmptyCurrency());

        currency[poolId] = currency_;

        emit UpdatedCurrency(poolId, currency_);
    }

    function setAddressFor(PoolId poolId, bytes32 key, address addr) external auth {
        require(exists(poolId), NonExistingPool(poolId));
        addressFor[poolId][key] = addr;

        emit SetAddressFor(poolId, key, addr);
    }

    function exists(PoolId poolId) public view returns (bool) {
        return address(shareClassManager[poolId]) != address(0);
    }
}
