// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IVaultFactory} from "src/spoke/factories/interfaces/IVaultFactory.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IVault} from "src/spoke/interfaces/IVault.sol";
import {IAsyncRequestManager} from "src/vaults/interfaces/IVaultManagers.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract AsyncVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    IAsyncRequestManager public immutable asyncRequestManager;

    constructor(address root_, IAsyncRequestManager asyncRequestManager_, address deployer) Auth(deployer) {
        root = root_;
        asyncRequestManager = asyncRequestManager_;
    }

    /// @inheritdoc IVaultFactory
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        IShareToken token,
        address[] calldata wards_
    ) public auth returns (IVault) {
        require(tokenId == 0, UnsupportedTokenId());
        AsyncVault vault = new AsyncVault(poolId, scId, asset, token, root, asyncRequestManager);

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
