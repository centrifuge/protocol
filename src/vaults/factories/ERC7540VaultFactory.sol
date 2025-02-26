// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC7540Vault} from "src/vault/ERC7540Vault.sol";
import {IERC7540VaultFactory} from "src/interfaces/factories/IERC7540VaultFactory.sol";
import {Auth} from "src/Auth.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract ERC7540VaultFactory is Auth, IERC7540VaultFactory {
    address public immutable root;

    constructor(address _root) Auth(msg.sender) {
        root = _root;
    }

    /// @inheritdoc IERC7540VaultFactory
    function newVault(
        uint64 poolId,
        bytes16 trancheId,
        address asset,
        address tranche,
        address escrow,
        address investmentManager,
        address[] calldata wards_
    ) public auth returns (address) {
        ERC7540Vault vault = new ERC7540Vault(poolId, trancheId, asset, tranche, root, escrow, investmentManager);

        vault.rely(root);
        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        Auth(investmentManager).rely(address(vault));
        vault.deny(address(this));
        return address(vault);
    }

    /// @inheritdoc IERC7540VaultFactory
    function denyVault(address vault, address investmentManager) public auth {
        Auth(investmentManager).deny(address(vault));
    }
}
