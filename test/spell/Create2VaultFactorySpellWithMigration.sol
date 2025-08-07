// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Create2VaultFactorySpellCommon} from "./Create2VaultFactorySpellCommon.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../src/common/libraries/MessageLib.sol";
import {ISpokeGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IVault} from "../../src/spoke/interfaces/IVault.sol";
import {VaultDetails} from "../../src/spoke/interfaces/ISpoke.sol";

import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";

/**
 * @title Create2VaultFactorySpellWithMigration
 * @notice Extends base spell with vault migration functionality
 * @dev Use this as parent class for spells that need to migrate existing vaults (Ethereum, Avalanche)
 */
abstract contract Create2VaultFactorySpellWithMigration is Create2VaultFactorySpellCommon {
    constructor(address asyncVaultFactory, address syncDepositVaultFactory)
        Create2VaultFactorySpellCommon(asyncVaultFactory, syncDepositVaultFactory)
    {}

    function execute() internal virtual override {
        _setupFactoryPermissions();
        _migrateVaults();
        _finalCleanup();
    }

    function _migrateVaults() internal virtual {
        address[] memory vaults = _getVaults();
        if (vaults.length == 0) return;

        ROOT.relyContract(address(SPOKE), address(this));

        for (uint256 i = 0; i < vaults.length; i++) {
            _migrateVault(vaults[i]);
        }

        ROOT.denyContract(address(SPOKE), address(this));
    }

    function _migrateVault(address oldVault) internal {
        // Extract parameters dynamically from vault
        IBaseVault vault = IBaseVault(oldVault);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        VaultDetails memory details = SPOKE.vaultDetails(IVault(oldVault));
        AssetId assetId = details.assetId;

        address factory = newAsyncVaultFactory;

        SPOKE.unlinkVault(poolId, scId, assetId, IVault(oldVault));

        // Deploy and link new vault in a single call (includes AsyncRequestManager.addVault)
        ISpokeGatewayHandler(address(SPOKE)).updateVault(poolId, scId, assetId, factory, VaultUpdateKind.DeployAndLink);
    }

    /// @dev Virtual function for network-specific vault lists which must be implemented by child contracts
    function _getVaults() internal pure virtual returns (address[] memory);
}
