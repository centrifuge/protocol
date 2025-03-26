// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {SyncDepositAsyncRedeemVault} from "src/vaults/SyncDepositAsyncRedeemVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

/// @title  Sync Vault Factory
/// @dev    Utility for deploying new vault contracts
// TODO(@wischli): Rename
contract SyncDepositAsyncRedeemVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    address public immutable syncInvestmentManager;
    address public immutable asyncInvestmentManager;

    constructor(address root_, address syncInvestmentManager_, address asyncInvestmentManager_) Auth(msg.sender) {
        root = root_;
        syncInvestmentManager = syncInvestmentManager_;
        asyncInvestmentManager = asyncInvestmentManager_;
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
        SyncDepositAsyncRedeemVault vault = new SyncDepositAsyncRedeemVault(
            poolId, trancheId, asset, tokenId, tranche, root, syncInvestmentManager, asyncInvestmentManager
        );

        vault.rely(root);
        vault.rely(syncInvestmentManager);
        vault.rely(asyncInvestmentManager);

        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return address(vault);
    }
}
