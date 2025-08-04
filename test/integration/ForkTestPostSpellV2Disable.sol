// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {IRoot} from "../../src/common/interfaces/IRoot.sol";
import {IShareToken} from "../../src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {IERC7540Deposit} from "../../src/misc/interfaces/IERC7540.sol";
import {DisableV2Eth} from "../spell/DisableV2Eth.sol";
import {ForkTestAsyncInvestments} from "./ForkTestInvestments.sol";
import {IntegrationConstants} from "./IntegrationConstants.sol";
import "forge-std/Test.sol";

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
contract ForkTestPostSpellV2Disable is ForkTestAsyncInvestments {
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
        _validateV3RootPermissions();
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

    // ═══════════════════════════════════════════════════════════════════════════════════════════════════
    // V3 ROOT PERMISSIONS VALIDATION
    // ═══════════════════════════════════════════════════════════════════════════════════════════════════

    /// @notice Validates that V3_ROOT has ward permissions on all Ethereum contracts, vaults, and share tokens
    function _validateV3RootPermissions() internal view {
        IRoot v3Root = spell.V3_ROOT();

        string memory config = vm.readFile("env/ethereum.json");

        // === CONTRACTS WITH ROOT PERMISSIONS (based on deployment scripts) ===

        // From HubDeployer
        _validateV3RootWardFromJson(config, "$.contracts.hubRegistry", "hubRegistry", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.accounting", "accounting", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.holdings", "holdings", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.shareClassManager", "shareClassManager", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.hub", "hub", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.hubHelpers", "hubHelpers", v3Root);

        // From SpokeDeployer
        _validateV3RootWardFromJson(config, "$.contracts.spoke", "spoke", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.balanceSheet", "balanceSheet", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.tokenFactory", "tokenFactory", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.contractUpdater", "contractUpdater", v3Root);

        // From VaultsDeployer
        _validateV3RootWardFromJson(config, "$.contracts.vaultRouter", "vaultRouter", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.asyncRequestManager", "asyncRequestManager", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.syncManager", "syncManager", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.routerEscrow", "routerEscrow", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.globalEscrow", "globalEscrow", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.asyncVaultFactory", "asyncVaultFactory", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.syncDepositVaultFactory", "syncDepositVaultFactory", v3Root);

        // From ValuationsDeployer
        _validateV3RootWardFromJson(config, "$.contracts.identityValuation", "identityValuation", v3Root);

        // === CONTRACTS WITHOUT ROOT PERMISSIONS (based on deployment scripts) ===
        // _validateV3RootWardFromJson(config, "$.contracts.guardian", "guardian", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.gasService", "gasService", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.gateway", "gateway", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.multiAdapter", "multiAdapter", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.messageProcessor", "messageProcessor", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.messageDispatcher", "messageDispatcher", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.poolEscrowFactory", "poolEscrowFactory", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.vaultDecoder", "vaultDecoder", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.circleDecoder", "circleDecoder", v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.onOfframpManagerFactory", "onOfframpManagerFactory",
        // v3Root);
        // _validateV3RootWardFromJson(config, "$.contracts.merkleProofManagerFactory", "merkleProofManagerFactory",
        // v3Root);

        // === HOOKS (from HooksDeployer) ===
        _validateV3RootWardFromJson(config, "$.contracts.freezeOnlyHook", "freezeOnlyHook", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.fullRestrictionsHook", "fullRestrictionsHook", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.freelyTransferableHook", "freelyTransferableHook", v3Root);
        _validateV3RootWardFromJson(
            config, "$.contracts.redemptionRestrictionsHook", "redemptionRestrictionsHook", v3Root
        );

        // === ADAPTERS (from AdaptersDeployer) ===
        _validateV3RootWardFromJson(config, "$.contracts.wormholeAdapter", "wormholeAdapter", v3Root);
        _validateV3RootWardFromJson(config, "$.contracts.axelarAdapter", "axelarAdapter", v3Root);

        // === V3 VAULTS ===
        _validateV3RootWard(spell.V3_JTRSY_VAULT(), "JTRSY V3 vault", v3Root);
        _validateV3RootWard(spell.V3_JAAA_VAULT(), "JAAA V3 vault", v3Root);
        _validateV3RootWard(0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9, "deJTRSY vault", v3Root);
        _validateV3RootWard(0x1121F4e21eD8B9BC1BB9A2952cDD8639aC897784, "deJAAA vault", v3Root);

        // === SHARE TOKENS ===
        _validateV3RootWard(address(spell.JTRSY_SHARE_TOKEN()), "JTRSY share token", v3Root);
        _validateV3RootWard(address(spell.JAAA_SHARE_TOKEN()), "JAAA share token", v3Root);
        _validateV3RootWard(0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72, "deJTRSY share token", v3Root);
        _validateV3RootWard(0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc, "deJAAA share token", v3Root);
    }

    /// @notice Helper function to validate V3_ROOT has ward permissions on contract from JSON config
    function _validateV3RootWardFromJson(
        string memory config,
        string memory jsonPath,
        string memory contractName,
        IRoot v3Root
    ) internal view {
        address contractAddr = vm.parseJsonAddress(config, jsonPath);
        _validateV3RootWard(contractAddr, contractName, v3Root);
    }

    /// @notice Helper function to validate V3_ROOT has ward permissions on a specific contract
    function _validateV3RootWard(address contractAddr, string memory contractName, IRoot v3Root) internal view {
        if (contractAddr.code.length == 0) {
            revert(string(abi.encodePacked(contractName, " has no code")));
        }

        assertEq(
            IAuth(contractAddr).wards(address(v3Root)),
            1,
            string(
                abi.encodePacked(
                    "V3_ROOT should have ward permissions on ", contractName, " (", vm.toString(contractAddr), ")"
                )
            )
        );
    }
}
