// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";
import {InstantDepositVault} from "src/vaults/InstantDepositVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract ERC7540VaultFactory is Auth, IVaultFactory {
    address public immutable root;
    address public immutable investmentManager;

    constructor(address _root, address _investmentManager) Auth(msg.sender) {
        root = _root;
        investmentManager = _investmentManager;
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
        ERC7540Vault vault = new ERC7540Vault(poolId, trancheId, asset, tokenId, tranche, root, investmentManager);

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
