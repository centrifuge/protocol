// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract AsyncVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    address public immutable investmentManager;

    constructor(address root_, address investmentManager_) Auth(msg.sender) {
        root = root_;
        investmentManager = investmentManager_;
    }

    /// @inheritdoc IVaultFactory
    function newVault(
        uint64 poolId,
        bytes16 trancheId,
        address asset,
        uint256 tokenId,
        address tranche,
        address, /* escrow */
        address[] calldata wards_
    ) public auth returns (address) {
        AsyncVault vault = new AsyncVault(poolId, trancheId, asset, tokenId, tranche, root, investmentManager);

        vault.rely(root);
        vault.rely(investmentManager);
        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return address(vault);
    }
}
