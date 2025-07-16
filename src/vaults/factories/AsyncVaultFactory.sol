// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "centrifuge-v3/src/misc/Auth.sol";

import {PoolId} from "centrifuge-v3/src/common/types/PoolId.sol";
import {ShareClassId} from "centrifuge-v3/src/common/types/ShareClassId.sol";

import {IVault} from "centrifuge-v3/src/spoke/interfaces/IVault.sol";
import {IShareToken} from "centrifuge-v3/src/spoke/interfaces/IShareToken.sol";
import {IVaultFactory} from "centrifuge-v3/src/spoke/factories/interfaces/IVaultFactory.sol";

import {AsyncVault} from "centrifuge-v3/src/vaults/AsyncVault.sol";
import {IAsyncRequestManager} from "centrifuge-v3/src/vaults/interfaces/IVaultManagers.sol";

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
