// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestLiveValidation} from "./ForkTestLiveValidation.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/spoke/interfaces/IVault.sol";
import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../../../src/spoke/interfaces/IBalanceSheet.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {DisableV2Common} from "../../spell/DisableV2Common.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @notice Interface for V2 investment managers
interface IV2InvestmentManager {
    function poolManager() external view returns (address);
}

/// @notice Interface for AsyncRequestManager V3.0.1
interface AsyncRequestManagerV3_0_1Like {
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (address vault);
}

/// @notice Interface for V2 vaults
interface IVaultV2Like {
    function share() external view returns (address);
    function asset() external view returns (address);
    function manager() external view returns (address);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256);
    function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256);
}

/// @notice Base fork test for validating post-spell V2 to V3 migration functionality
/// @dev Abstract contract providing shared testing framework for DisableV2 spell validation
abstract contract ForkTestPostSpellV2DisableCommon is ForkTestLiveValidation {
    // Shared state variables
    DisableV2Common public spell;
    bool public spellExecuted;
    address investor = makeAddr("INVESTOR");

    function setUp() public virtual override {
        super.setUp();

        spellExecuted = false;
        spell = _createSpell();

        _configureNetwork(); // Allow network-specific configuration
        _validateContractAddresses();
        _executeSpell();
    }

    //----------------------------------------------------------------------------------------------
    // SHARED TEST FUNCTIONS (All Networks)
    //----------------------------------------------------------------------------------------------

    function test_v3AsyncFlowsContinue() public virtual {
        address networkVault = _getNetworkVault();
        if (networkVault != address(0)) {
            completeAsyncDepositLocal(IBaseVault(networkVault), investor, depositAmount);
            completeAsyncRedeemLocal(IBaseVault(networkVault), investor, depositAmount);
        }
    }

    function test_v3RootHasPermissionsOnAllContracts() public view virtual {
        _validateV3RootPermissions();
    }

    function test_validateCompleteDeployment() public virtual override {
        validateDeployment();
    }

    function test_spellExecutionAndCleanup() public view virtual {
        _validateSpellCleanup();
    }

    function test_postSpellPermissions() public view virtual {
        _validateRootPermissionsIntact();
        _validateSpellPermissionsRevoked();
    }

    function test_basicV3Functionality() public view virtual {
        assertTrue(spell.done(), "Spell should be executed successfully");
    }

    function test_jtrsy_vaultAsyncFlowsPostSpell() public virtual {
        if (_canTestLocalAsyncFlow()) {
            completeAsyncDepositLocal(IBaseVault(spell.V3_JTRSY_VAULT()), investor, depositAmount);
            completeAsyncRedeemLocal(IBaseVault(spell.V3_JTRSY_VAULT()), investor, depositAmount);
        }
    }

    function test_completeAsyncDepositLocalFlow() public virtual override {
        if (_canTestLocalAsyncFlow()) {
            super.test_completeAsyncDepositLocalFlow();
        }
    }

    function test_completeAsyncRedeemLocalFlow() public virtual override {
        if (_canTestLocalAsyncFlow()) {
            super.test_completeAsyncRedeemLocalFlow();
        }
    }

    function test_v2OperationsDisabledPostSpell() public virtual {
        _validateV2OperationsDisabled();
    }

    function test_postSpellPermissionValidation() public view virtual {
        _validatePostSpellPermissions();
    }

    //----------------------------------------------------------------------------------------------
    // SPELL EXECUTION LOGIC
    //----------------------------------------------------------------------------------------------

    /// @notice Executes the spell with proper permissions and validation
    function _executeSpell() internal virtual {
        require(!spellExecuted, "Spell already executed in this test");
        spellExecuted = true;

        _grantSpellPermissions();
        spell.cast();

        assertTrue(spell.done(), "Spell execution should complete successfully");
    }

    /// @notice Grants ward permissions to spell on V3 root (and V2 root if applicable) using slot manipulation
    function _grantSpellPermissions() internal virtual {
        bytes32 wardSlot = keccak256(abi.encode(address(spell), uint256(0)));

        // Grant V3 permissions (all spells need this)
        vm.store(address(spell.V3_ROOT()), wardSlot, bytes32(uint256(1)));
        uint256 v3Ward = IAuth(address(spell.V3_ROOT())).wards(address(spell));
        assertEq(v3Ward, 1, "Spell should have V3 root permissions");

        // Grant V2 permissions (all networks have V2 JTRSY vault)
        _grantV2Permissions(wardSlot);
    }

    /// @notice Grants V2 permissions - all networks have V2 now
    function _grantV2Permissions(bytes32 wardSlot) internal virtual {
        vm.store(address(spell.V2_ROOT()), wardSlot, bytes32(uint256(1)));
        uint256 v2Ward = IAuth(address(spell.V2_ROOT())).wards(address(spell));
        assertEq(v2Ward, 1, "Spell should have V2 root permissions");
    }

    /// @notice Validates that all core contract addresses have deployed code
    function _validateContractAddresses() internal view virtual {
        assertTrue(address(spell.V2_ROOT()).code.length > 0, "V2 Root should have code");
        assertTrue(address(spell.V3_ROOT()).code.length > 0, "V3 Root should have code");
        assertTrue(spell.V3_FULL_RESTRICTIONS_HOOK().code.length > 0, "V3 Hook should have code");

        if (_canTestLocalAsyncFlow()) {
            assertTrue(spell.V3_JTRSY_VAULT().code.length > 0, "JTRSY V3 Vault should have code");
            assertTrue(address(spell.JTRSY_SHARE_TOKEN()).code.length > 0, "JTRSY Share Token should have code");
        }
    }

    //----------------------------------------------------------------------------------------------
    // VALIDATION FUNCTIONS
    //----------------------------------------------------------------------------------------------

    function _validateSpellCleanup() internal view virtual {
        assertTrue(spell.done(), "Spell should be marked as done");
        _validateSpellPermissionsRevoked();
    }

    function _validateRootPermissionsIntact() internal view virtual {
        // Base implementation - override in child contracts for network-specific validation
    }

    function _validateSpellPermissionsRevoked() internal view virtual {
        assertEq(
            IAuth(address(spell.V3_ROOT())).wards(address(spell)),
            0,
            "Spell should not have V3 root permissions after execution"
        );
        assertEq(
            IAuth(address(spell.V2_ROOT())).wards(address(spell)),
            0,
            "Spell should not have V2 root permissions after execution"
        );

        assertEq(
            IAuth(IntegrationConstants.SPOKE).wards(address(spell)),
            0,
            "Spell should not have V3 spoke permissions after execution"
        );
        assertEq(
            IAuth(address(spell.JTRSY_SHARE_TOKEN())).wards(address(spell)),
            0,
            "Spell should not have JTRSY permissions after execution"
        );
    }

    //----------------------------------------------------------------------------------------------
    // NETWORK-SPECIFIC ABSTRACT METHODS
    //----------------------------------------------------------------------------------------------

    function _createSpell() internal virtual returns (DisableV2Common);

    /// @notice Configure network-specific settings - override in child classes as needed
    function _configureNetwork() internal virtual {}

    /// @notice Abstract methods for network-specific values (used by non-Ethereum networks)
    function _centrifugeId() internal pure virtual returns (uint16) {
        return 0;
    }

    function _adminSafe() internal pure virtual returns (address) {
        return address(0);
    }

    function _jtrsyVaultAddress() internal view virtual returns (address) {
        return address(0);
    }

    function _getNetworkVault() internal view virtual returns (address) {
        // Only set for Ethereum due to hub == spoke chain
        if (_canTestLocalAsyncFlow()) {
            return spell.V3_JTRSY_VAULT();
        }
        return address(0);
    }

    function _canTestLocalAsyncFlow() internal pure virtual returns (bool);

    function _validateV2OperationsDisabled() internal virtual {
        // Override in child contracts to validate V2 operations are disabled
    }

    function _validateV2VaultOperationsFail(address vaultAddress) internal {
        IVaultV2Like vault = IVaultV2Like(vaultAddress);
        address asset = vault.asset();
        IShareToken shareToken = IShareToken(vault.share());

        // Test V2 deposit failure
        uint256 testDepositAmount = 100_000e6; // 100k USDC
        deal(asset, investor, testDepositAmount);
        vm.startPrank(investor);
        IERC20(asset).approve(vaultAddress, testDepositAmount);

        vm.expectRevert();
        vault.requestDeposit(testDepositAmount, investor, investor);
        vm.stopPrank();

        // Test V2 redeem failure
        uint256 testRedeemAmount = 50_000e18; // 50k shares
        deal(address(shareToken), investor, testRedeemAmount);
        vm.startPrank(investor);

        vm.expectRevert();
        vault.requestRedeem(testRedeemAmount, investor, investor);
        vm.stopPrank();
    }

    function _validatePostSpellPermissions() internal view virtual {
        _validateRootPermissionsIntact();
        _validateSpellPermissionsRevoked();

        // Validate JTRSY V3 hook is set (all networks)
        _validateV3HookSet(spell.JTRSY_SHARE_TOKEN(), "JTRSY");

        // Override in child contracts for network-specific V2 permission validation
    }

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

    //----------------------------------------------------------------------------------------------
    // V3 SHARE TOKEN DEPLOYMENT VALIDATION (Generalized)
    //----------------------------------------------------------------------------------------------

    /// @notice Validates V3 share token ward permissions
    /// @dev Generalized version that works for both JTRSY and JAAA tokens across all networks
    function _validateShareTokenWards(
        IShareToken shareToken,
        address balanceSheetAddress,
        address spokeAddress,
        string memory tokenName
    ) internal view override {
        assertEq(
            IAuth(address(shareToken)).wards(address(spell.V3_ROOT())),
            1,
            string(abi.encodePacked(tokenName, " share token should have V3_ROOT as ward"))
        );
        assertEq(
            IAuth(address(shareToken)).wards(balanceSheetAddress),
            1,
            string(abi.encodePacked(tokenName, " share token should have V3_BALANCE_SHEET as ward"))
        );
        assertEq(
            IAuth(address(shareToken)).wards(spokeAddress),
            1,
            string(abi.encodePacked(tokenName, " share token should have V3_SPOKE as ward"))
        );
    }

    /// @notice Validates spoke storage changes from V3 token deployment
    /// @dev Generalized version that works for both JTRSY and JAAA tokens across all networks
    function _validateSpokeDeploymentChanges(
        PoolId poolId,
        ShareClassId shareClassId,
        IShareToken shareToken,
        address vaultAddress,
        string memory tokenName
    ) internal view override {
        ISpoke spoke = ISpoke(IntegrationConstants.SPOKE);

        // Validate share token is linked to pool/share class
        IShareToken linkedShareToken = spoke.shareToken(poolId, shareClassId);
        assertEq(
            address(linkedShareToken),
            address(shareToken),
            string(abi.encodePacked(tokenName, " share token should be linked to pool/share class in spoke"))
        );

        // Validate pool is active
        assertTrue(spoke.isPoolActive(poolId), string(abi.encodePacked(tokenName, " pool should be active on spoke")));

        // Validate vault is linked (if vault address is provided)
        if (vaultAddress != address(0)) {
            assertTrue(
                spoke.isLinked(IVault(vaultAddress)),
                string(abi.encodePacked("Deployed V3 ", tokenName, " vault should be marked as linked in spoke"))
            );
        }
    }

    /// @notice Validates share token vault mapping points to deployed V3 vault
    /// @dev Generalized version that works for both JTRSY and JAAA tokens across all networks
    function _validateShareTokenVaultMapping(IShareToken shareToken, AssetId assetId, string memory tokenName)
        internal
        view
        override
    {
        // Get asset address from asset ID
        (address assetAddress,) = ISpoke(IntegrationConstants.SPOKE).idToAsset(assetId);

        // Share token's vault(asset) should point to deployed V3 vault
        address vaultFromShareToken = shareToken.vault(assetAddress);
        assertTrue(
            vaultFromShareToken != address(0),
            string(abi.encodePacked(tokenName, " share token vault mapping should point to deployed V3 vault"))
        );

        // Verify vault has deployed code
        assertTrue(
            vaultFromShareToken.code.length > 0,
            string(abi.encodePacked("V3 ", tokenName, " vault should have deployed code"))
        );
    }

    /// @notice Validates deployed V3 vault has correct configuration
    /// @dev Generalized version that works for both JTRSY and JAAA tokens across all networks
    function _validateDeployedV3Vault(
        IShareToken shareToken,
        AssetId assetId,
        PoolId poolId,
        ShareClassId shareClassId,
        string memory tokenName
    ) internal view override {
        // Get vault address from share token mapping
        (address assetAddress,) = ISpoke(IntegrationConstants.SPOKE).idToAsset(assetId);
        address v3VaultAddress = shareToken.vault(assetAddress);

        assertTrue(v3VaultAddress != address(0), string(abi.encodePacked("V3 ", tokenName, " vault should exist")));

        IBaseVault v3Vault = IBaseVault(v3VaultAddress);

        // Validate vault configuration
        assertEq(
            v3Vault.share(),
            address(shareToken),
            string(abi.encodePacked("V3 ", tokenName, " vault should have ", tokenName, " share token as its share"))
        );

        assertEq(
            PoolId.unwrap(v3Vault.poolId()),
            PoolId.unwrap(poolId),
            string(abi.encodePacked("V3 ", tokenName, " vault should have correct pool ID"))
        );

        assertEq(
            ShareClassId.unwrap(v3Vault.scId()),
            ShareClassId.unwrap(shareClassId),
            string(abi.encodePacked("V3 ", tokenName, " vault should have correct share class ID"))
        );
    }

    /// @notice Validates balance sheet manager assignment for a pool
    /// @dev Generalized version that works for any pool/request manager combination
    function _validateBalanceSheetManager(
        PoolId poolId,
        address requestManager,
        address balanceSheetAddress,
        string memory tokenName
    ) internal view override {
        IBalanceSheet balanceSheet = IBalanceSheet(balanceSheetAddress);

        // Verify request manager is set as manager for the pool
        assertTrue(
            balanceSheet.manager(poolId, requestManager),
            string(
                abi.encodePacked("RequestManager should be set as manager for ", tokenName, " pool in balance sheet")
            )
        );

        // Verify spell no longer has permissions on balance sheet
        assertEq(IAuth(balanceSheetAddress).wards(address(spell)), 0, "V3_BALANCE_SHEET should not have spell as ward");
    }
}
