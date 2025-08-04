// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IntegrationConstants} from "./IntegrationConstants.sol";
import {ForkTestLiveValidation} from "./ForkTestInvestments.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {IERC7540Deposit} from "../../src/misc/interfaces/IERC7540.sol";

import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";

import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";

import "forge-std/Test.sol";

import {DisableV2Eth} from "../spell/DisableV2Eth.sol";

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
    using CastLib for *;
    // Test configuration constants

    uint256 constant TEST_DEPOSIT_AMOUNT = 100_000e6; // 100k USDC
    uint256 constant TEST_REDEEM_AMOUNT = 50_000e18; // 50k shares

    DisableV2Eth public spell;
    bool public spellExecuted;

    function setUp() public override {
        vm.createSelectFork(IntegrationConstants.RPC_ETHEREUM);
        super.setUp();

        spellExecuted = false;
        spell = new DisableV2Eth();

        _validateContractAddresses();
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

    function test_postSpellCompleteValidation() public {
        _executeSpell();

        _validateV2OperationsDisabled();
        _validateV3AsyncFlowsContinue();
        _validatePostSpellPermissions();
        _validateSpellCleanup();
    }

    function test_v3AsyncFlowsContinuePostSpell() public {
        _executeSpell();
        _validateV3AsyncFlowsContinue();
    }

    function test_jtrsy_vaultAsyncFlowsPostSpell() public {
        _executeSpell();

        // Test that JTRSY V3 vault now supports V3 async flows
        address jtrsy_investor = makeAddr("JTRSY_V3_INVESTOR");
        _testVaultAsyncFlows(spell.V3_JTRSY_VAULT(), jtrsy_investor, "JTRSY_V3");
    }

    function test_jaaa_vaultAsyncFlowsPostSpell() public {
        _executeSpell();

        // Test that JAAA V3 vault now supports V3 async flows
        address jaaa_investor = makeAddr("JAAA_V3_INVESTOR");
        _testVaultAsyncFlows(spell.V3_JAAA_VAULT(), jaaa_investor, "JAAA_V3");
    }

    function test_v2OperationsDisabledPostSpell() public {
        _executeSpell();
        _validateV2OperationsDisabled();
    }

    function test_postSpellPermissionValidation() public {
        _executeSpell();
        _validatePostSpellPermissions();
    }

    function test_spellExecutionAndCleanup() public {
        _executeSpell();
        _validateSpellCleanup();
    }

    function test_v3RootHasPermissionsOnAllContracts() public view {
        _validateV3RootPermissions(spell.V3_ROOT());
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // INTERNAL VALIDATION FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    function _validateV3AsyncFlowsContinue() internal {
        address v3Investor = makeAddr("V3_INVESTOR");

        // Test existing V3 vault continues to work
        _completeAsyncDeposit(VAULT, v3Investor, depositAmount);
        _completeAsyncRedeem(VAULT, v3Investor, depositAmount);

        // Test newly enabled JTRSY V3 vault async flows
        address jtrsy_investor = makeAddr("JTRSY_V3_INVESTOR");
        _testVaultAsyncFlows(spell.V3_JTRSY_VAULT(), jtrsy_investor, "JTRSY_V3");

        // Test newly enabled JAAA V3 vault async flows
        address jaaa_investor = makeAddr("JAAA_V3_INVESTOR");
        _testVaultAsyncFlows(spell.V3_JAAA_VAULT(), jaaa_investor, "JAAA_V3");
    }

    function _validateV2OperationsDisabled() internal {
        address testInvestor = makeAddr("TEST_V2_INVESTOR");

        _validateV2VaultOperationsFail(spell.V2_JTRSY_VAULT_ADDRESS(), testInvestor);
        _validateV2VaultOperationsFail(spell.V2_JAAA_VAULT_ADDRESS(), testInvestor);
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

    function _validateV2VaultOperationsFail(address vaultAddress, address investor) internal {
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

    function _testVaultAsyncFlows(address vaultAddress, address investor, string memory vaultName) internal {
        IERC7540Deposit v3Vault = IERC7540Deposit(vaultAddress);
        IBaseVault baseVault = IBaseVault(vaultAddress);
        address assetAddress = baseVault.asset();

        deal(assetAddress, investor, TEST_DEPOSIT_AMOUNT);
        _addPoolMember(baseVault, investor);

        vm.startPrank(investor);
        IERC20(assetAddress).approve(vaultAddress, TEST_DEPOSIT_AMOUNT);

        uint256 requestId = v3Vault.requestDeposit(TEST_DEPOSIT_AMOUNT, investor, investor);
        // Verify pending request exists in V3 system (requestId 0 is valid)
        assertTrue(
            v3Vault.pendingDepositRequest(requestId, investor) > 0,
            string(abi.encodePacked(vaultName, " should have pending deposit request"))
        );
        vm.stopPrank();
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
