// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestLiveValidation} from "./ForkTestLiveValidation.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import "forge-std/Test.sol";

import {DisableV2Eth} from "../../spell/DisableV2Eth.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @notice Interface for V2 investment managers
interface IV2InvestmentManager {
    function poolManager() external view returns (address);
}

/// @notice Interface for V2 vaults
interface IVaultV2Like {
    function share() external view returns (address);
    function asset() external view returns (address);
    function manager() external view returns (address);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
}

/// @notice Fork test validating DisableV2Eth spell execution and post-spell V2/V3 state
contract ForkTestPostSpellV2Disable is ForkTestLiveValidation {
    uint256 constant TEST_DEPOSIT_AMOUNT = 100_000e6; // 100k USDC
    uint256 constant TEST_REDEEM_AMOUNT = 50_000e18; // 50k shares

    DisableV2Eth public spell;
    bool public spellExecuted;

    address investor = makeAddr("INVESTOR");

    function setUp() public override {
        vm.createSelectFork(IntegrationConstants.RPC_ETHEREUM);
        super.setUp();

        spellExecuted = false;
        spell = new DisableV2Eth();

        _validateContractAddresses();

        _executeSpell();
    }

    /// @notice Validates that all contract addresses have deployed code
    function _validateContractAddresses() internal view {
        assertTrue(address(spell.V2_ROOT()).code.length > 0, "V2 Root should have code");
        assertTrue(address(spell.V3_ROOT()).code.length > 0, "V3 Root should have code");
        assertTrue(spell.V3_FULL_RESTRICTIONS_HOOK().code.length > 0, "V3 Hook should have code");
        assertTrue(spell.V2_JTRSY_VAULT_ADDRESS().code.length > 0, "JTRSY V2 Vault should have code");
        assertTrue(spell.V2_JAAA_VAULT_ADDRESS().code.length > 0, "JAAA V2 Vault should have code");
        assertTrue(spell.V3_JTRSY_VAULT().code.length > 0, "JTRSY V3 Vault should have code");
        assertTrue(spell.V3_JAAA_VAULT().code.length > 0, "JAAA V3 Vault should have code");
        assertTrue(address(spell.JTRSY_SHARE_TOKEN()).code.length > 0, "JTRSY Share Token should have code");
        assertTrue(address(spell.JAAA_SHARE_TOKEN()).code.length > 0, "JAAA Share Token should have code");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // MAIN TEST FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function test_v3AsyncFlowsContinuePostSpell() public {
        _completeAsyncDeposit(VAULT, investor, depositAmount);
        _completeAsyncRedeem(VAULT, investor, depositAmount);
    }

    function test_jtrsy_vaultAsyncFlowsPostSpell() public {
        _completeAsyncDeposit(IBaseVault(spell.V3_JTRSY_VAULT()), investor, depositAmount);
        _completeAsyncRedeem(IBaseVault(spell.V3_JTRSY_VAULT()), investor, depositAmount);
    }

    function test_jaaa_vaultAsyncFlowsPostSpell() public {
        _completeAsyncDeposit(IBaseVault(spell.V3_JAAA_VAULT()), investor, depositAmount);
        _completeAsyncRedeem(IBaseVault(spell.V3_JAAA_VAULT()), investor, depositAmount);
    }

    function test_v2OperationsDisabledPostSpell() public {
        _validateV2OperationsDisabled();
    }

    function test_postSpellPermissionValidation() public view {
        _validatePostSpellPermissions();
    }

    function test_spellExecutionAndCleanup() public view {
        _validateSpellCleanup();
    }

    function test_v3RootHasPermissionsOnAllContracts() public view {
        super._validateV3RootPermissions();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // INTERNAL VALIDATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function _validateV2OperationsDisabled() internal {
        _validateV2VaultOperationsFail(spell.V2_JTRSY_VAULT_ADDRESS());
        _validateV2VaultOperationsFail(spell.V2_JAAA_VAULT_ADDRESS());
    }

    function _validatePostSpellPermissions() internal view {
        _validateVaultPermissions(spell.V2_JTRSY_VAULT_ADDRESS(), spell.JTRSY_SHARE_TOKEN(), "JTRSY");
        _validateVaultPermissions(spell.V2_JAAA_VAULT_ADDRESS(), spell.JAAA_SHARE_TOKEN(), "JAAA");

        _validateRootPermissionsIntact();

        _validateSpellPermissionsRevoked();
    }

    function _validateSpellCleanup() internal view {
        assertTrue(spell.done(), "Spell should be marked as done");
        _validateSpellPermissionsRevoked();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // SPELL EXECUTION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function _executeSpell() internal {
        require(!spellExecuted, "Spell already executed in this test");
        spellExecuted = true;

        _grantSpellPermissions();
        spell.cast();

        assertTrue(spell.done(), "Spell execution should complete successfully");
    }

    function _grantSpellPermissions() internal {
        // Grant ward permissions to spell on both V2 and V3 roots using slot manipulation
        bytes32 wardSlot = keccak256(abi.encode(address(spell), uint256(0)));

        vm.store(address(spell.V2_ROOT()), wardSlot, bytes32(uint256(1)));
        vm.store(address(spell.V3_ROOT()), wardSlot, bytes32(uint256(1)));

        uint256 v2Ward = IAuth(address(spell.V2_ROOT())).wards(address(spell));
        uint256 v3Ward = IAuth(address(spell.V3_ROOT())).wards(address(spell));

        assertEq(v2Ward, 1, "Spell should have V2 root permissions");
        assertEq(v3Ward, 1, "Spell should have V3 root permissions");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // V2 VALIDATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function _validateV2VaultOperationsFail(address vaultAddress) internal {
        IVaultV2Like vault = IVaultV2Like(vaultAddress);
        address asset = vault.asset();
        IShareToken shareToken = IShareToken(vault.share());

        // Test V2 deposit failure
        deal(asset, investor, TEST_DEPOSIT_AMOUNT);
        vm.startPrank(investor);
        IERC20(asset).approve(vaultAddress, TEST_DEPOSIT_AMOUNT);

        vm.expectRevert();
        vault.requestDeposit(TEST_DEPOSIT_AMOUNT, investor, investor);
        vm.stopPrank();

        // Test V2 redeem failure
        deal(address(shareToken), investor, TEST_REDEEM_AMOUNT);
        vm.startPrank(investor);

        vm.expectRevert();
        vault.requestRedeem(TEST_REDEEM_AMOUNT, investor, investor);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // PERMISSION VALIDATION HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function _validateVaultPermissions(address vaultAddress, IShareToken shareToken, string memory tokenName)
        internal
        view
    {
        IVaultV2Like vault = IVaultV2Like(vaultAddress);
        address investmentManager = vault.manager();
        address poolManager = IV2InvestmentManager(investmentManager).poolManager();

        _validateV2PermissionsRemoved(shareToken, investmentManager, poolManager, tokenName);
        _validateV3HookSet(shareToken, tokenName);
    }

    function _validateV2PermissionsRemoved(
        IShareToken shareToken,
        address investmentManager,
        address poolManager,
        string memory tokenName
    ) internal view {
        assertEq(
            IAuth(address(shareToken)).wards(poolManager),
            0,
            string(abi.encodePacked("Pool manager should not have permissions on ", tokenName, " share token"))
        );

        assertEq(
            IAuth(address(shareToken)).wards(investmentManager),
            0,
            string(abi.encodePacked("Investment manager should not have permissions on ", tokenName, " share token"))
        );

        assertEq(
            IAuth(address(shareToken)).wards(address(spell.V2_ROOT())),
            1,
            string(abi.encodePacked("V2 Root should still have permissions on ", tokenName, " share token"))
        );
    }

    function _validateV3HookSet(IShareToken shareToken, string memory tokenName) internal view {
        assertEq(
            shareToken.hook(),
            spell.V3_FULL_RESTRICTIONS_HOOK(),
            string(abi.encodePacked(tokenName, " share token should have V3 hook set"))
        );
    }

    function _validateRootPermissionsIntact() internal view {
        assertTrue(
            address(spell.V2_ROOT()) != address(0) && address(spell.V3_ROOT()) != address(0),
            "Root contracts should remain accessible"
        );

        // Verify roots are still functional (not paused)
        assertFalse(spell.V2_ROOT().paused(), "V2 root should not be paused");
        assertFalse(spell.V3_ROOT().paused(), "V3 root should not be paused");
    }

    function _validateSpellPermissionsRevoked() internal view {
        assertEq(
            IAuth(address(spell.V2_ROOT())).wards(address(spell)),
            0,
            "Spell should not have V2 root permissions after cleanup"
        );

        assertEq(
            IAuth(address(spell.V3_ROOT())).wards(address(spell)),
            0,
            "Spell should not have V3 root permissions after cleanup"
        );
    }
}
