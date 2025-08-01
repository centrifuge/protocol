// Network: Plume (Chain ID: 98866)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultPermissionSpell} from "./VaultPermissionSpell.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";

/**
 * @title VaultPermissionSpellPlume
 * @notice Plume-specific implementation of the VaultPermissionSpell
 *         Handles the single SyncDepositVault on Plume network
 *
 * This spell updates the SyncDepositVault to use the new AsyncRequestManager
 * while keeping the SyncManager unchanged for synchronous deposits.
 *
 * For SyncDepositVault:
 * - `manager` field -> new AsyncRequestManager (for price queries and common operations)
 * - `asyncRedeemManager` field -> new AsyncRequestManager (for async redemptions)
 * - `syncDepositManager` field -> unchanged SyncManager (for sync deposits)
 *
 * The base spell's unlink/relink pattern works correctly because spoke.linkVault
 * uses vault.manager() which points to AsyncRequestManager.
 */
contract VaultPermissionSpellPlume is VaultPermissionSpell {
    PoolId public constant PLUME_POOL_ID = PoolId.wrap(1125899906842625);
    address public constant PLUME_SYNC_DEPOSIT_VAULT = address(0x374Bc3D556fBc9feC0b9537c259DCB7935f7E5bf);

    constructor(address newAsyncRequestManager, address newAsyncVaultFactory, address newSyncDepositVaultFactory)
        VaultPermissionSpell(newAsyncRequestManager, newAsyncVaultFactory, newSyncDepositVaultFactory)
    {}

    /// @dev Override to return the Plume SyncDepositVault
    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](1);
        vaults[0] = PLUME_SYNC_DEPOSIT_VAULT;
        return vaults;
    }

    /// @dev Override to return pool IDs affected by vault updates
    function _getPools() internal pure override returns (PoolId[] memory) {
        PoolId[] memory poolIds = new PoolId[](1);
        poolIds[0] = PLUME_POOL_ID;
        return poolIds;
    }
}