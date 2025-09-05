// Network: Ethereum (Chain ID: 1)
// Deployed Address: 0x37271F54911A22156B39ab08E9f9738Cc9bf55e4
// Source Branch: spell/004-create2-factories
// CREATE3 Deterministic Deployment

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {IRoot} from "../../src/common/interfaces/IRoot.sol";

import {ISpoke} from "../../src/spoke/interfaces/ISpoke.sol";

import {IAsyncRequestManager} from "../../src/vaults/interfaces/IVaultManagers.sol";

/**
 * @title Create2VaultFactorySpellCommon
 * @notice Base governance spell to update vault factories to CREATE2 (optimized for chains without migrations)
 * @dev This contract only handles factory permission setup. For chains that need vault migrations,
 *      use Create2VaultFactorySpellWithMigration as the parent class instead.
 */
contract Create2VaultFactorySpellCommon {
    bool public done;
    string public constant description = "Update vault factories to CREATE2";

    // System contracts
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IAsyncRequestManager public constant ASYNC_REQUEST_MANAGER =
        IAsyncRequestManager(0xf06f89A1b6C601235729A689595571B7455Dd433);
    address public constant SYNC_MANAGER = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;

    address public constant OLD_ASYNC_VAULT_FACTORY = 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385;
    address public constant OLD_SYNC_DEPOSIT_VAULT_FACTORY = 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc;

    address public immutable newAsyncVaultFactory;
    address public immutable newSyncDepositVaultFactory;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory) {
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
        _finalCleanup();
    }

    function _setupFactoryPermissions() internal {
        ROOT.relyContract(address(ASYNC_REQUEST_MANAGER), address(this));
        IAuth(address(ASYNC_REQUEST_MANAGER)).deny(OLD_ASYNC_VAULT_FACTORY);
        IAuth(address(ASYNC_REQUEST_MANAGER)).deny(OLD_SYNC_DEPOSIT_VAULT_FACTORY);

        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newAsyncVaultFactory);
        IAuth(address(ASYNC_REQUEST_MANAGER)).rely(newSyncDepositVaultFactory);
        ROOT.denyContract(address(ASYNC_REQUEST_MANAGER), address(this));

        // Revoke old factory permissions on Spoke
        ROOT.relyContract(OLD_ASYNC_VAULT_FACTORY, address(this));
        IAuth(OLD_ASYNC_VAULT_FACTORY).deny(address(SPOKE));
        ROOT.denyContract(OLD_ASYNC_VAULT_FACTORY, address(this));

        ROOT.relyContract(OLD_SYNC_DEPOSIT_VAULT_FACTORY, address(this));
        IAuth(OLD_SYNC_DEPOSIT_VAULT_FACTORY).deny(address(SPOKE));
        ROOT.denyContract(OLD_SYNC_DEPOSIT_VAULT_FACTORY, address(this));

        ROOT.relyContract(newAsyncVaultFactory, address(this));
        IAuth(newAsyncVaultFactory).rely(address(ROOT));
        IAuth(newAsyncVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newAsyncVaultFactory, address(this));

        ROOT.relyContract(newSyncDepositVaultFactory, address(this));
        IAuth(newSyncDepositVaultFactory).rely(address(ROOT));
        IAuth(newSyncDepositVaultFactory).rely(address(SPOKE));
        ROOT.denyContract(newSyncDepositVaultFactory, address(this));
    }

    function _finalCleanup() internal virtual {
        IAuth(address(ROOT)).deny(address(this));
    }
}

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

/**
 * @title Create2VaultFactorySpellEthereum
 * @notice Ethereum-specific governance spell to migrate 4 vaults to CREATE2 deployment
 * @dev Extends Create2VaultFactorySpellWithMigration to handle Ethereum collision resolution vaults
 */
contract Create2VaultFactorySpellEthereum is Create2VaultFactorySpellWithMigration {
    // deJAAA ETH USDC Vault
    address public constant VAULT_1 = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;
    // deJTRSY ETH USDC Vault
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;
    // deJTRSY ETH JTRSY Vault
    address public constant VAULT_3 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    // deJAAA ETH JAAA Vault
    address public constant VAULT_4 = 0x2D38c58Cc7d4DdD6B4DaF7b3539902a7667F4519;

    constructor(address asyncVaultFactory, address syncDepositVaultFactory)
        Create2VaultFactorySpellWithMigration(asyncVaultFactory, syncDepositVaultFactory)
    {}

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](4);
        vaults[0] = VAULT_1;
        vaults[1] = VAULT_2;
        vaults[2] = VAULT_3;
        vaults[3] = VAULT_4;
        return vaults;
    }
}