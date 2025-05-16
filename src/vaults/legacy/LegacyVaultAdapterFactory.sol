// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/investments/IAsyncRequestManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";
import {ILegacyVault} from "src/vaults/legacy/interfaces/ILegacyVault.sol";
import {LegacyVaultAdapter} from "src/vaults/legacy/LegacyVaultAdapter.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract LegacyVaultAdapterFactory is Auth, IVaultFactory {
    address public immutable root;
    IAsyncRequestManager public immutable asyncRequestManager;

    mapping(PoolId newPoolId => mapping(ShareClassId newScId => mapping(address asset => ILegacyVault))) legacyVault;

    constructor(address root_, IAsyncRequestManager asyncRequestManager_, address deployer) Auth(deployer) {
        root = root_;
        asyncRequestManager = asyncRequestManager_;
    }

    /// @inheritdoc ILegacyVaultAdapterFactory
    function addLegacyVault(PoolId newPoolId, ShareClassId newScId, address asset, ILegacyVault legacyVault_)
        public
        auth
    {
        // All checks for legacy vault adapter setup against asset, poolId, etc. are done in the constructor of
        // LegacyVaultAdapter
        legacyVault[newPoolId][newScId][asset] = legacyVault_;
    }

    /// @inheritdoc IVaultFactory
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        IShareToken token,
        address[] calldata wards_
    ) public auth returns (IBaseVault) {
        require(tokenId == 0, UnsupportedTokenId());
        ILegacyVault legacyVault_ = legacyVault[newPoolId][newScId][asset];
        require(legacyVault_ != address(0), LegacyVaultNotAdded());

        ILegacyVaultAdapter vault = new LegacyVaultAdapter(
            legacyVault_,
            poolId,
            legacyVault_.poolId(),
            scId,
            legacyVault_.trancheId(),
            asset,
            token,
            root,
            asyncRequestManager
        );

        vault.rely(root);
        vault.rely(address(asyncRequestManager));
        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return vault;
    }
}
