// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth, IAuth} from "../../misc/Auth.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

import {IVault} from "../../spoke/interfaces/IVault.sol";
import {IShareToken} from "../../spoke/interfaces/IShareToken.sol";
import {IVaultFactory} from "../../spoke/factories/interfaces/IVaultFactory.sol";

import {AsyncVault} from "../AsyncVault.sol";
import {IAsyncRequestManager} from "../interfaces/IVaultManagers.sol";

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

        IAuth(address(asyncRequestManager)).rely(address(vault));

        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return vault;
    }
}
