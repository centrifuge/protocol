// Network: Ethereum (Chain ID: 1)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IEscrow} from "../../src/misc/interfaces/IEscrow.sol";

import {PoolId} from "../../src/common/types/PoolId.sol";
import {AssetId} from "../../src/common/types/AssetId.sol";
import {IRoot} from "../../src/common/interfaces/IRoot.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {ISpokeGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";
import {IBalanceSheetGatewayHandler} from "../../src/common/interfaces/IGatewayHandlers.sol";

import {IBalanceSheet} from "../../src/spoke/interfaces/IBalanceSheet.sol";
import {ISpoke, VaultDetails} from "../../src/spoke/interfaces/ISpoke.sol";

import {BaseVault} from "../../src/vaults/BaseVaults.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRequestManager} from "../../src/vaults/interfaces/IVaultManagers.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

/**
 * @title VaultPermissionSpellEthereum
 * @notice Ethereum-specific governance spell with 5 vaults (includes VAULT_5 which doesn't exist on Avalanche)
 */
contract VaultPermissionSpellEthereum is VaultPermissionSpell {
    // JAAA (Avalanche) & deJAAA (Ethereum) USD vaults
    address public constant VAULT_1 = 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784;
    // deJAAA (Avalanche) & deJTRSY (Ethereum) USD vaults
    address public constant VAULT_2 = 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9;
    // deJTRSY (Avalanche & Ethereum) USD vaults
    address public constant VAULT_3 = 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958;
    // JTRSY (Avalanche & Ethereum) USD vaults
    address public constant VAULT_4 = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
    // This address for JAAA USD Vault only exists on Ethereum mainnet currently
    address public constant VAULT_5 = 0x4880799eE5200fC58DA299e965df644fBf46780B;

    address public constant V2_JTRSY_VAULT_ADDRESS = 0x36036fFd9B1C6966ab23209E073c68Eb9A992f50;
    address public constant V2_JAAA_VAULT_ADDRESS = 0xE9d1f733F406D4bbbDFac6D4CfCD2e13A6ee1d01;

    address public constant USDC_TOKEN = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    // VAULT_1: 0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784
    PoolId public constant POOL_ID_1 = PoolId.wrap(281474976710659);
    // VAULT_2: 0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9
    PoolId public constant POOL_ID_2 = PoolId.wrap(281474976710660);
    // VAULT_3: 0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958
    PoolId public constant POOL_ID_3 = PoolId.wrap(281474976710660);
    // VAULT_4: 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A
    PoolId public constant POOL_ID_4 = PoolId.wrap(281474976710662);
    // VAULT_5: 0x4880799eE5200fC58DA299e965df644fBf46780B
    PoolId public constant POOL_ID_5 = PoolId.wrap(281474976710663);

    constructor(address newAsyncRequestManager, address newAsyncVaultFactory, address newSyncDepositVaultFactory)
        VaultPermissionSpell(newAsyncRequestManager, newAsyncVaultFactory, newSyncDepositVaultFactory)
    {}

    function _relinkV2Vaults() internal override {
        ROOT.relyContract(address(JTRSY_SHARE_TOKEN), address(this));
        JTRSY_SHARE_TOKEN.updateVault(USDC_TOKEN, V2_JTRSY_VAULT_ADDRESS);
        ROOT.denyContract(address(JTRSY_SHARE_TOKEN), address(this));

        ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(this));
        JAAA_SHARE_TOKEN.updateVault(USDC_TOKEN, V2_JAAA_VAULT_ADDRESS);
        ROOT.denyContract(address(JAAA_SHARE_TOKEN), address(this));
    }

    function _getVaults() internal pure override returns (address[] memory) {
        address[] memory vaults = new address[](5);
        vaults[0] = VAULT_1;
        vaults[1] = VAULT_2;
        vaults[2] = VAULT_3;
        vaults[3] = VAULT_4;
        vaults[4] = VAULT_5;
        return vaults;
    }

    function _getPools() internal pure override returns (PoolId[] memory) {
        PoolId[] memory poolIds = new PoolId[](5);
        poolIds[0] = POOL_ID_1;
        poolIds[1] = POOL_ID_2;
        poolIds[2] = POOL_ID_3;
        poolIds[3] = POOL_ID_4;
        poolIds[4] = POOL_ID_5;
        return poolIds;
    }
}

/**
 * @title VaultPermissionSpell
 * @notice Governance spell to update AsyncRequestManager and factory contracts
 *
 * This spell replaces the deployed contracts from v3 tag with current commit versions:
 * - AsyncRequestManager: 0x58d57896EBbF000c293327ADf33689D0a7Fd3d9A -> NEW_ASYNC_REQUEST_MANAGER
 * - AsyncVaultFactory: 0xE01Ce2e604CCe985A06FA4F4bCD17f1F08417BF3 -> NEW_ASYNC_VAULT_FACTORY
 * - SyncDepositVaultFactory: 0x3568184784E8ACCaacF51A7F710a3DE0144E4f29 -> NEW_SYNC_DEPOSIT_VAULT_FACTORY
 *
 * The spell handles:
 * 1. Updating deployed vaults to use the new AsyncRequestManager
 * 2. Wiring the new AsyncRequestManager to Spoke and BalanceSheet
 * 3. Setting up all required permissions for new contracts
 * 4. Revoking permissions from old contracts
 * 5. Endorsing new contracts on ROOT
 *
 * This is the base spell that handles common permissions. Network-specific implementations
 * (VaultPermissionSpellEthereum, VaultPermissionSpellAvalanche) override _getVaults() to include their vaults.
 */
contract VaultPermissionSpell {
    bool public done;
    string public constant description = "Update AsyncRequestManager and vault permissions to current commit";

    // Unchanged v3.0.0 system contracts
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IBalanceSheet public constant BALANCE_SHEET = IBalanceSheet(0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda);
    IEscrow public constant GLOBAL_ESCROW = IEscrow(0x43d51be0B6dE2199A2396bA604114d24383F91E9);

    // To be replaced v3.0.0 contracts
    IAsyncRequestManager public constant OLD_ASYNC_REQUEST_MANAGER =
        IAsyncRequestManager(0x58d57896EBbF000c293327ADf33689D0a7Fd3d9A);
    address public constant OLD_ASYNC_VAULT_FACTORY = 0xE01Ce2e604CCe985A06FA4F4bCD17f1F08417BF3;
    address public constant OLD_SYNC_DEPOSIT_VAULT_FACTORY = 0x3568184784E8ACCaacF51A7F710a3DE0144E4f29;

    // Replacing v3.0.1 contracts
    // These will be set in the constructor by the deployment process
    IAsyncRequestManager public immutable NEW_ASYNC_REQUEST_MANAGER;
    address public immutable NEW_ASYNC_VAULT_FACTORY;
    address public immutable NEW_SYNC_DEPOSIT_VAULT_FACTORY;

    // Vault constants moved to network-specific implementations

    constructor(address newAsyncRequestManager, address newAsyncVaultFactory, address newSyncDepositVaultFactory) {
        NEW_ASYNC_REQUEST_MANAGER = IAsyncRequestManager(newAsyncRequestManager);
        NEW_ASYNC_VAULT_FACTORY = newAsyncVaultFactory;
        NEW_SYNC_DEPOSIT_VAULT_FACTORY = newSyncDepositVaultFactory;
    }

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        _setupNewPermissions();

        _updateVaultManagerRelationships();

        _relinkV2Vaults();

        _revokeOldPermissions();

        _finalCleanup();
    }

    /// @dev Update vault manager relationships
    ///      NOTE: For existing vaults with linked assets, we need to unlink, update manager, then relink
    function _updateVaultManagerRelationships() internal virtual {
        address[] memory vaults = _getVaults();

        // Grant new AsyncRequestManager permission to be called by SPOKE before linking vaults
        ROOT.relyContract(address(NEW_ASYNC_REQUEST_MANAGER), address(this));
        IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(address(SPOKE));

        if (vaults.length > 0) {
            ROOT.relyContract(address(SPOKE), address(this));

            for (uint256 i = 0; i < vaults.length; i++) {
                IBaseVault vault = IBaseVault(vaults[i]);
                PoolId poolId = vault.poolId();
                ShareClassId scId = vault.scId();
                VaultDetails memory details = SPOKE.vaultDetails(vault);
                AssetId assetId = details.assetId;

                ROOT.relyContract(vaults[i], address(this));

                // Unlink with old manager
                SPOKE.unlinkVault(poolId, scId, assetId, vault);

                // Important: Must be called before linkVault, otherwise oldManager.addVault is called
                BaseVault(vaults[i]).file(bytes32("manager"), address(NEW_ASYNC_REQUEST_MANAGER));
                BaseVault(vaults[i]).file(bytes32("asyncRedeemManager"), address(NEW_ASYNC_REQUEST_MANAGER));
                IAuth(vaults[i]).rely(address(NEW_ASYNC_REQUEST_MANAGER));
                IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(vaults[i]);

                // Update spoke's request manager
                ISpokeGatewayHandler(address(SPOKE)).setRequestManager(
                    poolId, scId, assetId, address(NEW_ASYNC_REQUEST_MANAGER)
                );

                ROOT.denyContract(vaults[i], address(this));

                // Link with new manager
                SPOKE.linkVault(poolId, scId, assetId, vault);
            }

            ROOT.denyContract(address(SPOKE), address(this));
        }

        ROOT.denyContract(address(NEW_ASYNC_REQUEST_MANAGER), address(this));
    }

    function _relinkV2Vaults() internal virtual {}

    /// @dev Set up all required permissions for new contracts based on VaultsDeployer
    function _setupNewPermissions() internal {
        ROOT.relyContract(address(NEW_ASYNC_REQUEST_MANAGER), address(this));
        IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(address(SPOKE));
        IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(address(ROOT));
        IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(NEW_SYNC_DEPOSIT_VAULT_FACTORY);
        IAuth(address(NEW_ASYNC_REQUEST_MANAGER)).rely(NEW_ASYNC_VAULT_FACTORY);
        NEW_ASYNC_REQUEST_MANAGER.file("spoke", address(SPOKE));
        NEW_ASYNC_REQUEST_MANAGER.file("balanceSheet", address(BALANCE_SHEET));
        ROOT.denyContract(address(NEW_ASYNC_REQUEST_MANAGER), address(this));

        ROOT.endorse(address(NEW_ASYNC_REQUEST_MANAGER));

        ROOT.relyContract(NEW_ASYNC_VAULT_FACTORY, address(this));
        IAuth(NEW_ASYNC_VAULT_FACTORY).rely(address(SPOKE));
        IAuth(NEW_ASYNC_VAULT_FACTORY).rely(address(ROOT));
        ROOT.denyContract(NEW_ASYNC_VAULT_FACTORY, address(this));

        ROOT.relyContract(NEW_SYNC_DEPOSIT_VAULT_FACTORY, address(this));
        IAuth(NEW_SYNC_DEPOSIT_VAULT_FACTORY).rely(address(SPOKE));
        IAuth(NEW_SYNC_DEPOSIT_VAULT_FACTORY).rely(address(ROOT));
        ROOT.denyContract(NEW_SYNC_DEPOSIT_VAULT_FACTORY, address(this));

        ROOT.relyContract(address(GLOBAL_ESCROW), address(this));
        IAuth(address(GLOBAL_ESCROW)).rely(address(NEW_ASYNC_REQUEST_MANAGER));
        ROOT.denyContract(address(GLOBAL_ESCROW), address(this));

        _updateBalanceSheetManagers();
    }

    /// @dev Update BalanceSheet managers for all pools affected by vault updates
    function _updateBalanceSheetManagers() internal virtual {
        PoolId[] memory poolIds = _getPools();
        if (poolIds.length == 0) return;

        ROOT.relyContract(address(BALANCE_SHEET), address(this));

        for (uint256 i = 0; i < poolIds.length; i++) {
            IBalanceSheetGatewayHandler(address(BALANCE_SHEET)).updateManager(
                poolIds[i], address(NEW_ASYNC_REQUEST_MANAGER), true
            );

            IBalanceSheetGatewayHandler(address(BALANCE_SHEET)).updateManager(
                poolIds[i], address(OLD_ASYNC_REQUEST_MANAGER), false
            );
        }

        ROOT.denyContract(address(BALANCE_SHEET), address(this));
    }

    /// @dev Revoke all permissions from old contracts (more or less reverse of _setupNewPermissions())
    ///      NOTE: We want to retain root permission to old contracts just to be safe
    function _revokeOldPermissions() internal virtual {
        ROOT.relyContract(address(GLOBAL_ESCROW), address(this));
        IAuth(address(GLOBAL_ESCROW)).deny(address(OLD_ASYNC_REQUEST_MANAGER));
        ROOT.denyContract(address(GLOBAL_ESCROW), address(this));

        address[] memory vaults = _getVaults();

        ROOT.relyContract(address(OLD_ASYNC_REQUEST_MANAGER), address(this));
        for (uint256 i = 0; i < vaults.length; i++) {
            ROOT.relyContract(vaults[i], address(this));

            IAuth(vaults[i]).deny(address(OLD_ASYNC_REQUEST_MANAGER));
            IAuth(address(OLD_ASYNC_REQUEST_MANAGER)).deny(vaults[i]);

            ROOT.denyContract(vaults[i], address(this));
        }
        IAuth(address(OLD_ASYNC_REQUEST_MANAGER)).deny(address(SPOKE));
        ROOT.denyContract(address(OLD_ASYNC_REQUEST_MANAGER), address(this));

        ROOT.veto(address(OLD_ASYNC_REQUEST_MANAGER));

        _revokeFactoryPermissions(OLD_ASYNC_VAULT_FACTORY);
        _revokeFactoryPermissions(OLD_SYNC_DEPOSIT_VAULT_FACTORY);
    }

    /// @dev Deny spell permissions from root
    function _finalCleanup() internal {
        IAuth(address(ROOT)).deny(address(this));
    }

    function _getVaults() internal pure virtual returns (address[] memory) {
        return new address[](0);
    }

    function _getPools() internal pure virtual returns (PoolId[] memory) {
        return new PoolId[](0);
    }

    function _revokeFactoryPermissions(address factory) internal {
        ROOT.relyContract(factory, address(this));
        IAuth(factory).deny(address(SPOKE));
        ROOT.denyContract(factory, address(this));
    }
}