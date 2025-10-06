// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IShareToken} from "./interfaces/IShareToken.sol";
import {IVault, VaultKind} from "./interfaces/IVault.sol";
import {VaultDetails, ISpoke} from "./interfaces/ISpoke.sol";
import {IVaultRegistry} from "./interfaces/IVaultRegistry.sol";
import {IVaultFactory} from "./factories/interfaces/IVaultFactory.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";

import {VaultUpdateKind} from "../messaging/libraries/MessageLib.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {IRequestManager} from "../interfaces/IRequestManager.sol";
import {IVaultRegistryGatewayHandler} from "../interfaces/IGatewayHandlers.sol";

/// @title  VaultRegistry
/// @notice This contract manages vault deployment, linking, and unlinking operations for pools and share classes
contract VaultRegistry is Auth, Recoverable, IVaultRegistry, IVaultRegistryGatewayHandler {
    ISpoke public spoke;

    mapping(IVault => VaultDetails) internal _vaultDetails;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => mapping(IRequestManager => IVault)))) public vault;

    constructor(address initialWard) Auth(initialWard) {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRegistry
    function file(bytes32 what, address data) external auth {
        if (what == "spoke") spoke = ISpoke(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // Vault management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRegistryGatewayHandler
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind
    ) external auth {
        if (kind == VaultUpdateKind.DeployAndLink) {
            IVault vault_ = deployVault(poolId, scId, assetId, IVaultFactory(vaultOrFactory));
            linkVault(poolId, scId, assetId, vault_);
        } else {
            IVault vault_ = IVault(vaultOrFactory);

            if (kind == VaultUpdateKind.Link) linkVault(poolId, scId, assetId, vault_);
            else if (kind == VaultUpdateKind.Unlink) unlinkVault(poolId, scId, assetId, vault_);
            else revert MalformedVaultUpdateMessage(); // Unreachable due the enum check
        }
    }

    /// @inheritdoc IVaultRegistry
    function deployVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVaultFactory factory)
        public
        auth
        returns (IVault)
    {
        (address asset, uint256 tokenId) = spoke.idToAsset(assetId);
        IShareToken shareToken = spoke.shareToken(poolId, scId);

        IVault vault_ = factory.newVault(poolId, scId, asset, tokenId, shareToken, new address[](0));

        // We need to check if there's a request manager for async vaults
        if (vault_.vaultKind() == VaultKind.Async) {
            require(address(spoke.requestManager(poolId)) != address(0), InvalidRequestManager());
        }

        registerVault(poolId, scId, assetId, asset, tokenId, factory, vault_);

        return vault_;
    }

    /// @inheritdoc IVaultRegistry
    /// @dev Extracted from deployVault to be used in migrations
    function registerVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address asset,
        uint256 tokenId,
        IVaultFactory factory,
        IVault vault_
    ) public auth {
        _vaultDetails[vault_] = VaultDetails(assetId, asset, tokenId, false);
        emit DeployVault(poolId, scId, asset, tokenId, factory, vault_, vault_.vaultKind());
    }

    /// @inheritdoc IVaultRegistry
    function linkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_) public auth {
        require(vault_.poolId() == poolId, InvalidVault());
        require(vault_.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = spoke.idToAsset(assetId);
        IRequestManager requestManager = spoke.requestManager(poolId);

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(vaultDetails_.asset != address(0), UnknownVault());
        require(!vaultDetails_.isLinked, AlreadyLinkedVault());

        vault[poolId][scId][assetId][requestManager] = vault_;
        vaultDetails_.isLinked = true;

        if (tokenId == 0) {
            spoke.setShareTokenVault(poolId, scId, asset, address(vault_));
        }

        emit LinkVault(poolId, scId, asset, tokenId, vault_);
    }

    /// @inheritdoc IVaultRegistry
    function unlinkVault(PoolId poolId, ShareClassId scId, AssetId assetId, IVault vault_) public auth {
        require(vault_.poolId() == poolId, InvalidVault());
        require(vault_.scId() == scId, InvalidVault());

        (address asset, uint256 tokenId) = spoke.idToAsset(assetId);
        IRequestManager requestManager = spoke.requestManager(poolId);

        VaultDetails storage vaultDetails_ = _vaultDetails[vault_];
        require(vaultDetails_.asset != address(0), UnknownVault());
        require(vaultDetails_.isLinked, AlreadyUnlinkedVault());

        delete vault[poolId][scId][assetId][requestManager];
        vaultDetails_.isLinked = false;

        if (tokenId == 0) {
            spoke.setShareTokenVault(poolId, scId, asset, address(0));
        }

        emit UnlinkVault(poolId, scId, asset, tokenId, vault_);
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRegistry
    function vaultDetails(IVault vault_) public view returns (VaultDetails memory details) {
        details = _vaultDetails[vault_];
        require(details.asset != address(0), UnknownVault());
    }

    /// @inheritdoc IVaultRegistry
    function isLinked(IVault vault_) public view returns (bool) {
        return _vaultDetails[vault_].isLinked;
    }
}
