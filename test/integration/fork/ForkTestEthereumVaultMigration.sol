// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestLiveValidation} from "./ForkTestLiveValidation.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IPoolEscrowFactory} from "../../../src/common/factories/interfaces/IPoolEscrowFactory.sol";

import {IVault} from "../../../src/spoke/interfaces/IVault.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncVaultFactory} from "../../../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../../../src/vaults/factories/SyncDepositVaultFactory.sol";
import {IAsyncRequestManager, ISyncDepositManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import "forge-std/Test.sol";

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {VaultMigrationSpellEthereum} from "../../../env/spell/VaultMigrationSpellEthereum.sol";

interface RestrictionManagerLike {
    function updateMember(address token, address user, uint64 validUntil) external;
}

/// @notice Fork test for VaultMigrationSpellEthereum spell execution
contract ForkTestEthereumVaultMigration is ForkTestLiveValidation {
    using CastLib for *;

    address public constant INVESTOR = address(0x123456789);
    uint128 public constant TEST_AMOUNT = 1000e6;

    VaultMigrationSpellEthereum public spell;
    bool public spellExecuted;
    address[3] public newVaults; // Vault addresses post-migration

    /// @notice Get old vault addresses from spell (single source of truth)
    function _getOldVaults() internal view returns (address[] memory) {
        address[] memory vaults = new address[](3);
        vaults[0] = spell.VAULT_1();
        vaults[1] = spell.VAULT_2();
        vaults[2] = spell.VAULT_3();
        return vaults;
    }

    //----------------------------------------------------------------------------------------------
    // SETUP & CONFIGURATION
    //----------------------------------------------------------------------------------------------

    function setUp() public override {
        super.setUp();

        // Deploy factories first to simulate deployment before spell 
        asyncVaultFactory = address(
            new AsyncVaultFactory(
                IntegrationConstants.ROOT,
                IAsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER),
                address(this)
            )
        );

        syncDepositVaultFactory = address(
            new SyncDepositVaultFactory(
                IntegrationConstants.ROOT,
                ISyncDepositManager(IntegrationConstants.SYNC_MANAGER),
                IAsyncRequestManager(IntegrationConstants.ASYNC_REQUEST_MANAGER),
                address(this)
            )
        );

        // Set up wards to root which happens on deployment
        IAuth(asyncVaultFactory).rely(IntegrationConstants.ROOT);
        IAuth(syncDepositVaultFactory).rely(IntegrationConstants.ROOT);

        vm.label(asyncVaultFactory, "NewAsyncVaultFactory");
        vm.label(syncDepositVaultFactory, "NewSyncDepositVaultFactory");

        // Create spell with factory addresses
        spell = new VaultMigrationSpellEthereum(asyncVaultFactory, syncDepositVaultFactory);
    }

    //----------------------------------------------------------------------------------------------
    // TEST FUNCTIONS
    //----------------------------------------------------------------------------------------------

    function test_completeVaultMigration() public {
        _executeSpell();
        _captureActualVaultAddresses();
        _validateVaultMigrations();
        _validateNewVaultsWorking();
    }

    function test_spellAlreadyCast() public {
        _executeSpell();

        vm.expectRevert("spell-already-cast");
        spell.cast();
    }

    function test_validateVaultDeployment() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(_getOldVaults()[i].code.length > 0, "Old vault should have code");
        }
    }

    function test_validateCompleteDeployment() public override {
        _executeSpell();

        super.test_validateCompleteDeployment();
    }

    //----------------------------------------------------------------------------------------------
    // SPELL EXECUTION
    //----------------------------------------------------------------------------------------------

    function _executeSpell() internal {
        require(!spellExecuted, "Spell already executed");
        spellExecuted = true;

        _grantSpellPermissions();
        spell.cast();

        assertTrue(spell.done(), "Spell execution should complete successfully");
    }

    function _grantSpellPermissions() internal {
        bytes32 wardSlot = keccak256(abi.encode(address(spell), uint256(0)));
        vm.store(address(spell.ROOT()), wardSlot, bytes32(uint256(1)));

        uint256 rootWard = IAuth(address(spell.ROOT())).wards(address(spell));
        assertEq(rootWard, 1, "Spell should have ROOT permissions");
    }

    //----------------------------------------------------------------------------------------------
    // VAULT ADDRESS MANAGEMENT
    //----------------------------------------------------------------------------------------------

    function _captureActualVaultAddresses() internal {
        // Phase 1: Generate new vault addresses using CREATE2 deterministic deployment
        for (uint256 i = 0; i < 3; i++) {
            address oldVault = _getOldVaults()[i];
            IBaseVault vault = IBaseVault(oldVault);

            // Extract vault parameters needed for CREATE2 salt generation
            PoolId poolId = vault.poolId();
            ShareClassId scId = vault.scId();
            address asset = vault.asset();

            // Generate deterministic salt matching factory logic
            bytes32 salt = keccak256(abi.encode(poolId, scId, asset));

            // Compute CREATE2 address with full constructor parameters
            newVaults[i] = _computeCreate2Address(
                asyncVaultFactory,
                salt,
                keccak256(
                    abi.encodePacked(
                        type(AsyncVault).creationCode,
                        abi.encode(
                            poolId,
                            scId,
                            asset,
                            vault.share(),
                            IntegrationConstants.ROOT,
                            IntegrationConstants.ASYNC_REQUEST_MANAGER
                        )
                    )
                )
            );
        }

        // Phase 2: Validate deployment success and spoke linking
        for (uint256 i = 0; i < 3; i++) {
            assertTrue(newVaults[i].code.length > 0, "New vault should have code");
            assertTrue(spell.SPOKE().isLinked(IVault(newVaults[i])), "New vault should be linked");
        }
    }

    /// @notice Compute CREATE2 address for a contract deployment
    /// @param deployer The address of the deployer (factory)
    /// @param salt The salt used for CREATE2
    /// @param initCodeHash The keccak256 hash of the init code
    /// @return The computed CREATE2 address
    function _computeCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    //----------------------------------------------------------------------------------------------
    // VALIDATION FUNCTIONS
    //----------------------------------------------------------------------------------------------

    function _validateVaultMigrations() internal view {
        // Validate old vaults are disabled
        for (uint256 i = 0; i < 3; i++) {
            address oldVault = _getOldVaults()[i];
            assertFalse(spell.SPOKE().isLinked(IVault(oldVault)), "Old vault should be unlinked");
        }

        // Validate new vaults are working
        for (uint256 i = 0; i < 3; i++) {
            _validateVaultConfiguration(_getOldVaults()[i], newVaults[i]);
        }
    }

    function _validateNewVaultsWorking() internal {
        for (uint256 i = 0; i < 3; i++) {
            _testAsyncFlows(newVaults[i]);
        }
    }

    function _validateVaultConfiguration(address oldVault, address newVault) internal view {
        AsyncVault oldAsyncVault = AsyncVault(oldVault);
        AsyncVault newAsyncVault = AsyncVault(newVault);

        assertTrue(PoolId.unwrap(oldAsyncVault.poolId()) == PoolId.unwrap(newAsyncVault.poolId()), "Pool ID should match");
        assertTrue(ShareClassId.unwrap(oldAsyncVault.scId()) == ShareClassId.unwrap(newAsyncVault.scId()), "Share class ID should match");
        assertEq(oldAsyncVault.asset(), newAsyncVault.asset(), "Asset should match");
        assertEq(oldAsyncVault.share(), newAsyncVault.share(), "Share token should match");
        assertEq(address(oldAsyncVault.manager()), address(newAsyncVault.manager()), "Manager should match");
        assertEq(
            address(oldAsyncVault.asyncRedeemManager()), address(newAsyncVault.asyncRedeemManager()), "Async redeem manager should match"
        );
        assertEq(address(oldAsyncVault.root()), address(newAsyncVault.root()), "Root should match");
        assertEq(oldAsyncVault.deploymentChainId(), newAsyncVault.deploymentChainId(), "Deployment chain ID should match");
        assertEq(newAsyncVault.totalAssets(), oldAsyncVault.totalAssets(), "Total assets should match");
        assertEq(oldAsyncVault.pricePerShare(), newAsyncVault.pricePerShare(), "Price per share should match");
    }

    function _testAsyncFlows(address vaultAddress) internal {
        IBaseVault vault = IBaseVault(vaultAddress);

        if (isShareToken(vault.asset())) {
            _enableShareTokenInvestments(vault, INVESTOR);
        }

        // Test async deposit and redeem flows
        _completeAsyncDeposit(vault, INVESTOR, TEST_AMOUNT);
        _completeAsyncRedeem(vault, INVESTOR, TEST_AMOUNT);
    }

    //----------------------------------------------------------------------------------------------
    // UTILITY FUNCTIONS
    //----------------------------------------------------------------------------------------------

    /// @notice Enable share token investments by updating restriction manager permissions
    /// @param vault The vault to enable investments for
    /// @param investor The investor address to grant permissions to
    function _enableShareTokenInvestments(IBaseVault vault, address investor) internal {
        address poolEscrow =
            address(IPoolEscrowFactory(IntegrationConstants.POOL_ESCROW_FACTORY).escrow(vault.poolId()));

        vm.startPrank(IntegrationConstants.V2_ROOT);
        RestrictionManagerLike(IntegrationConstants.V2_RESTRICTION_MANAGER).updateMember(
            vault.asset(), IntegrationConstants.GLOBAL_ESCROW, type(uint64).max
        );
        RestrictionManagerLike(IntegrationConstants.V2_RESTRICTION_MANAGER).updateMember(
            vault.asset(), poolEscrow, type(uint64).max
        );
        RestrictionManagerLike(IntegrationConstants.V2_RESTRICTION_MANAGER).updateMember(
            vault.asset(), investor, type(uint64).max
        );
        vm.stopPrank();
    }
}
