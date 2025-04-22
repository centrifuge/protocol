// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract AsyncVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    address public immutable investmentManager;
    IPoolEscrowProvider public immutable poolEscrowProvider;

    constructor(address root_, address investmentManager_, IPoolEscrowProvider poolEscrowProvider_, address deployer)
        Auth(deployer)
    {
        root = root_;
        investmentManager = investmentManager_;
        poolEscrowProvider = poolEscrowProvider_;
    }

    /// @inheritdoc IVaultFactory
    function newVault(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address token,
        address, /* escrow */
        address[] calldata wards_
    ) public auth returns (address) {
        AsyncVault vault =
            new AsyncVault(poolId, scId, asset, tokenId, token, root, investmentManager, poolEscrowProvider);

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
