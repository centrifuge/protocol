// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IBridgingHook} from "./interfaces/IBridgingHook.sol";
import {IHubRequestManager} from "./interfaces/IHubRequestManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC6909Decimals} from "../../misc/interfaces/IERC6909.sol";

import {AssetId} from "../types/AssetId.sol";
import {PoolId, newPoolId} from "../types/PoolId.sol";
import {IHubPolicy} from "../utils/interfaces/IPolicy.sol";

/// @title  Hub Registry
/// @notice Registry of all known pools, currencies, and assets.
contract HubRegistry is Auth, IHubRegistry {
    using MathLib for uint256;

    /// @dev PricingLib conversions assume decimals <= 18; mirrors the spoke-side bound in Spoke.registerAsset.
    uint8 internal constant MAX_DECIMALS = 18;

    // Assets
    mapping(AssetId => AssetInfo) public asset;

    // Pools
    mapping(PoolId => bytes) public metadata;
    mapping(PoolId => AssetId) public currency;
    mapping(PoolId => mapping(address => bool)) public manager;

    // Policy & authorization ledger
    mapping(PoolId => PolicyInfo) internal _policy;
    mapping(bytes32 authId => uint48 validAfter) public authorizedAfter;

    // Dependencies
    mapping(PoolId => IBridgingHook) public bridgingHook;
    mapping(PoolId => mapping(uint16 centrifugeId => IHubRequestManager)) public hubRequestManager;

    constructor(address deployer) Auth(deployer) {}

    //----------------------------------------------------------------------------------------------
    // Registration methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function registerAsset(AssetId assetId, uint8 decimals_) external auth {
        require(!assetId.isNull(), EmptyAssetId());
        require(decimals_ <= MAX_DECIMALS, TooManyDecimals());
        require(!asset[assetId].registered, AssetAlreadyRegistered());

        asset[assetId] = AssetInfo(true, decimals_);

        emit NewAsset(assetId, decimals_);
    }

    /// @inheritdoc IHubRegistry
    function registerPool(PoolId poolId_, address manager_, AssetId currency_) external auth {
        require(!poolId_.isNull(), InvalidPool());
        require(manager_ != address(0), EmptyAccount());
        require(!currency_.isNull(), EmptyCurrency());
        require(isRegistered(currency_), AssetNotFound());
        require(currency[poolId_].isNull(), PoolAlreadyRegistered());

        manager[poolId_][manager_] = true;
        currency[poolId_] = currency_;

        emit NewPool(poolId_, manager_, currency_);
    }

    //----------------------------------------------------------------------------------------------
    // Update methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function updateManager(PoolId poolId_, address who, bool canManage) external auth {
        require(exists(poolId_), NonExistingPool());
        require(who != address(0), EmptyAccount());

        manager[poolId_][who] = canManage;

        emit UpdateManager(poolId_, who, canManage);
    }

    /// @inheritdoc IHubRegistry
    function setMetadata(PoolId poolId_, bytes calldata metadata_) external auth {
        require(exists(poolId_), NonExistingPool());

        metadata[poolId_] = metadata_;

        emit SetMetadata(poolId_, metadata_);
    }

    /// @inheritdoc IHubRegistry
    function updateCurrency(PoolId poolId_, AssetId currency_) external auth {
        require(exists(poolId_), NonExistingPool());
        require(!currency_.isNull(), EmptyCurrency());
        require(isRegistered(currency_), AssetNotFound());
        require(asset[currency_].decimals == asset[currency[poolId_]].decimals, CurrencyDecimalsMismatch());

        currency[poolId_] = currency_;

        emit UpdateCurrency(poolId_, currency_);
    }

    /// @inheritdoc IHubRegistry
    function setPolicy(PoolId poolId_, IHubPolicy policy_) external auth {
        require(exists(poolId_), NonExistingPool());

        _policy[poolId_] = PolicyInfo(policy_, _policy[poolId_].nonce + 1);

        emit SetPolicy(poolId_, policy_);
    }

    /// @inheritdoc IHubRegistry
    function setHubRequestManager(PoolId poolId_, uint16 centrifugeId, IHubRequestManager manager_) external auth {
        require(exists(poolId_), NonExistingPool());

        hubRequestManager[poolId_][centrifugeId] = manager_;

        emit SetHubRequestManager(poolId_, centrifugeId, manager_);
    }

    /// @inheritdoc IHubRegistry
    function setBridgingHook(PoolId poolId_, IBridgingHook hook_) external auth {
        require(exists(poolId_), NonExistingPool());

        bridgingHook[poolId_] = hook_;
        emit SetBridgingHook(poolId_, address(hook_));
    }

    //----------------------------------------------------------------------------------------------
    // Authorization ledger
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubRegistry
    function initiateAuthorization(PoolId poolId_, address caller, bytes calldata data) external auth {
        PolicyInfo memory info = _policy[poolId_];
        require(address(info.policy) != address(0), PolicyNotInstalled());

        // Only an out-of-policy call may be authorized: an in-policy call would mature instantly.
        uint48 delaySeconds = info.policy.authorizationDelay(poolId_, caller, data);
        require(delaySeconds != 0, InPolicy());

        // Reject re-authorizing: it would silently reset the maturity clock, so cancel first.
        bytes32 id = _authId(poolId_, address(info.policy), info.nonce, data);
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
        PolicyInfo memory info = _policy[poolId_];
        require(msg.sender == address(info.policy), CallerNotPolicy());

        bytes32 id = _authId(poolId_, address(info.policy), info.nonce, data);
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
    /// @dev `authId` is namespaced by the pool's current policy and its install nonce, so any
    ///      policy change makes every pending authorization unreachable without needing to enumerate
    ///      and clear them — including re-installing a previously used policy address, which must not
    ///      resurrect authorizations matured under its earlier tenure.
    function authId(PoolId poolId_, bytes calldata data) public view returns (bytes32) {
        PolicyInfo memory info = _policy[poolId_];
        return _authId(poolId_, address(info.policy), info.nonce, data);
    }

    /// @dev Computes the id from an already-loaded policy slot, so callers holding it avoid re-reading it.
    function _authId(PoolId poolId_, address policy_, uint64 nonce_, bytes calldata data)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(poolId_.raw(), policy_, nonce_, data));
    }

    /// @inheritdoc IHubRegistry
    function policy(PoolId poolId_) external view returns (IHubPolicy) {
        return _policy[poolId_].policy;
    }

    /// @inheritdoc IHubRegistry
    function policyNonce(PoolId poolId_) external view returns (uint64) {
        return _policy[poolId_].nonce;
    }

    /// @inheritdoc IHubRegistry
    function poolId(uint16 centrifugeId, uint48 postfix) public pure returns (PoolId poolId_) {
        poolId_ = newPoolId(centrifugeId, postfix);
    }

    /// @inheritdoc IHubRegistry
    function decimals(AssetId assetId) public view returns (uint8 decimals_) {
        AssetInfo memory info = asset[assetId];
        require(info.registered, AssetNotFound());
        decimals_ = info.decimals;
    }

    /// @inheritdoc IHubRegistry
    function decimals(PoolId poolId_) public view returns (uint8 decimals_) {
        AssetInfo memory info = asset[currency[poolId_]];
        require(info.registered, AssetNotFound());
        decimals_ = info.decimals;
    }

    /// @inheritdoc IERC6909Decimals
    function decimals(uint256 asset_) external view returns (uint8 decimals_) {
        AssetInfo memory info = asset[AssetId.wrap(asset_.toUint128())];
        require(info.registered, AssetNotFound());
        decimals_ = info.decimals;
    }

    /// @inheritdoc IHubRegistry
    function exists(PoolId poolId_) public view returns (bool) {
        return !currency[poolId_].isNull();
    }

    /// @inheritdoc IHubRegistry
    function isRegistered(AssetId assetId) public view returns (bool) {
        return asset[assetId].registered;
    }
}
