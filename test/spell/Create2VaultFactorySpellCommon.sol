// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {IRoot} from "../../src/common/interfaces/IRoot.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../src/common/libraries/MessageLib.sol";
import {ISpokeGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IVault} from "../../src/spoke/interfaces/IVault.sol";
import {ISpoke, VaultDetails} from "../../src/spoke/interfaces/ISpoke.sol";

import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncVaultFactory} from "../../src/vaults/factories/AsyncVaultFactory.sol";
import {IAsyncRequestManager} from "../../src/vaults/interfaces/IVaultManagers.sol";
import {SyncDepositVaultFactory} from "../../src/vaults/factories/SyncDepositVaultFactory.sol";

/**
 * @title Create2VaultFactorySpellCommon
 * @notice Base governance spell to update vault factories to CREATE2 and migrate vaults
 *
 * This spell handles:
 * 1. Deploying new CREATE2-enabled vault factories (AsyncVaultFactory and SyncDepositVaultFactory)
 * 2. Updating SPOKE with new factory addresses
 * 3. Setting up all required permissions for new factories
 * 4. Providing migration template for network-specific vaults
 *
 * Network-specific spells inherit from this base and override _getVaults() to include their vaults.
 * All 5 vaults specified are async vaults and will use AsyncVaultFactory for migration.
 */
contract Create2VaultFactorySpellCommon {
    bool public done;
    string public constant description = "Update vault factories to CREATE2 and migrate vaults";

    // System contracts (from IntegrationConstants)
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IAsyncRequestManager public constant ASYNC_REQUEST_MANAGER =
        IAsyncRequestManager(0xf06f89A1b6C601235729A689595571B7455Dd433);
    address public constant SYNC_MANAGER = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;

    // Old factories (to be replaced)
    address public constant OLD_ASYNC_VAULT_FACTORY = 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385;
    address public constant OLD_SYNC_DEPOSIT_VAULT_FACTORY = 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc;

    address public immutable newAsyncVaultFactory;
    address public immutable newSyncDepositVaultFactory;

    /// @param asyncVaultFactory Address of the deployed AsyncVaultFactory
    /// @param syncDepositVaultFactory Address of the deployed SyncDepositVaultFactory
    constructor(address asyncVaultFactory, address syncDepositVaultFactory) {
        require(asyncVaultFactory != address(0), "Invalid async vault factory");
        require(syncDepositVaultFactory != address(0), "Invalid sync deposit vault factory");
        newAsyncVaultFactory = asyncVaultFactory;
        newSyncDepositVaultFactory = syncDepositVaultFactory;
    }

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        _setupFactoryPermissions();
        _migrateVaults();
        _finalCleanup();
    }

    /// @dev Set up all required permissions for new factories based on VaultsDeployer
    function _setupFactoryPermissions() internal {
        ROOT.relyContract(address(ASYNC_REQUEST_MANAGER), address(this));
        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newAsyncVaultFactory);
        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newSyncDepositVaultFactory);
        ROOT.denyContract(address(ASYNC_REQUEST_MANAGER), address(this));

        ROOT.relyContract(newAsyncVaultFactory, address(this));
        IAuth(newAsyncVaultFactory).rely(address(ROOT));
        IAuth(newAsyncVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newAsyncVaultFactory, address(this));

        ROOT.relyContract(newSyncDepositVaultFactory, address(this));
        IAuth(newSyncDepositVaultFactory).rely(address(ROOT));
        IAuth(newSyncDepositVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newSyncDepositVaultFactory, address(this));
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

        // Deploy and link new vault in a single call - this automatically handles AsyncRequestManager registration
        ISpokeGatewayHandler(address(SPOKE)).updateVault(poolId, scId, assetId, factory, VaultUpdateKind.DeployAndLink);
    }

    /// @dev Virtual function for network-specific vault lists
    function _getVaults() internal pure virtual returns (address[] memory) {
        return new address[](0); // Base returns empty, networks override
    }

    /// @dev Final cleanup - deny spell permissions from root
    function _finalCleanup() internal virtual {
        IAuth(address(ROOT)).deny(address(this));
    }
}
