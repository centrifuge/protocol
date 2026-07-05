// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IManifest} from "./interfaces/IManifest.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IBridgingHook} from "./interfaces/IBridgingHook.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "../../misc/interfaces/IERC6909.sol";

import {AssetId} from "../types/AssetId.sol";
import {PoolId, newPoolId} from "../types/PoolId.sol";

/// @title  Hub Registry
/// @notice Registry of all known pools, currencies, and assets.
contract HubRegistry is Auth, IHubRegistry {
    using MathLib for uint256;

    mapping(AssetId => uint8) internal _decimals;

    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => AssetId) public currency;
    mapping(PoolId => IManifest) public manifest;
    mapping(PoolId => IBridgingHook) public bridgingHook;
    mapping(PoolId => mapping(address => bool)) public manager;
    mapping(PoolId => mapping(bytes32 => address)) public dependency;
    mapping(bytes32 authId => uint48 validAfter) public authorizedAfter;
    mapping(PoolId => mapping(uint16 centrifugeId => IHubRequestManager)) public hubRequestManager;

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
    function updateDependency(PoolId poolId_, bytes32 what, address dependency_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));

        dependency[poolId_][what] = dependency_;

        emit UpdateDependency(poolId_, what, dependency_);
    }

    /// @inheritdoc IHubRegistry
    function updateCurrency(PoolId poolId_, AssetId currency_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));
        require(!currency_.isNull(), EmptyCurrency());
        require(isRegistered(currency_), AssetNotFound());

        currency[poolId_] = currency_;

        emit UpdateCurrency(poolId_, currency_);
    }

    /// @inheritdoc IHubRegistry
    function setManifest(PoolId poolId_, IManifest manifest_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));

        manifest[poolId_] = manifest_;

        emit SetManifest(poolId_, manifest_);
    }

    /// @inheritdoc IHubRegistry
    function setHubRequestManager(PoolId poolId_, uint16 centrifugeId, IHubRequestManager manager_) external auth {
        require(exists(poolId_), NonExistingPool(poolId_));

        hubRequestManager[poolId_][centrifugeId] = manager_;

        emit SetHubRequestManager(poolId_, centrifugeId, manager_);
    }

    //----------------------------------------------------------------------------------------------
    // Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function authorize(PoolId poolId_, address caller, bytes calldata data) external auth {
        IManifest m = manifest[poolId_];
        require(address(m) != address(0), NoManifest());

        // Only an out-of-policy call may be authorized: an in-policy call would mature instantly.
        uint48 delaySeconds = m.classify(poolId_, caller, data);
        require(delaySeconds != 0, InPolicy());

        // Reject re-authorizing: it would silently reset the maturity clock, so cancel first.
        bytes32 id = _authId(poolId_, address(m), data);
        require(authorizedAfter[id] == 0, AlreadyAuthorized());

        uint48 validAfter = uint48(block.timestamp) + delaySeconds;
        authorizedAfter[id] = validAfter;
        emit AuthorizationScheduled(poolId_, caller, id, validAfter, data);
    }

    /// @inheritdoc IHubRegistry
    function cancelAuthorization(PoolId poolId_, address caller, bytes calldata data) external auth {
        bytes32 id = authId(poolId_, data);
        // Revert on a no-op cancel rather than writing a misleading audit entry.
        require(authorizedAfter[id] != 0, Unauthorized());
        delete authorizedAfter[id];
        emit AuthorizationCanceled(poolId_, caller, id);
    }

    /// @inheritdoc IHubRegistry
    function consumeAuthorization(PoolId poolId_, address caller, bytes calldata data, uint48 expiry) external {
        IManifest m = manifest[poolId_];
        require(msg.sender == address(m), NotManifest());

        bytes32 id = _authId(poolId_, address(m), data);
        uint48 validAfter = authorizedAfter[id];
        // Matured and not yet expired: a stale auth fails closed, so it can't be fired much later (once
        // the baseline has drifted) with no fresh veto window.
        require(
            validAfter != 0 && block.timestamp >= validAfter && block.timestamp <= uint256(validAfter) + expiry,
            Unauthorized()
        );
        delete authorizedAfter[id];
        emit AuthorizationConsumed(poolId_, caller, id);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    /// @dev `authId` is namespaced by the pool's current manifest, so swapping the manifest makes every
    ///      pending authorization unreachable (the new manifest computes different ids) without needing
    ///      to enumerate and clear them — mirroring the old per-manifest-instance ledger.
    function authId(PoolId poolId_, bytes calldata data) public view returns (bytes32) {
        return _authId(poolId_, address(manifest[poolId_]), data);
    }

    /// @dev Computes the id from an already-loaded manifest, so callers holding it avoid re-reading the slot.
    function _authId(PoolId poolId_, address manifest_, bytes calldata data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId_.raw(), manifest_, data));
    }

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
    function decimals(PoolId poolId_) public view returns (uint8 decimals_) {
        decimals_ = _decimals[currency[poolId_]];
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

    /// @inheritdoc IHubRegistry
    function setBridgingHook(PoolId poolId_, IBridgingHook hook_) external auth {
        bridgingHook[poolId_] = hook_;
        emit SetBridgingHook(poolId_, address(hook_));
    }
}
