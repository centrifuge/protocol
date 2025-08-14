// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestPostSpellV2DisableCommon} from "./ForkTestPostSpellV2DisableCommon.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {ISpokeGatewayHandler} from "../../../src/common/interfaces/IGatewayHandlers.sol";

import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/spoke/interfaces/IVault.sol";
import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {DisableV2Base} from "../../spell/DisableV2Base.sol";
import {DisableV2Common} from "../../spell/DisableV2Common.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

interface AsyncRequestManagerV3_0_1Like {
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (address vault);
}

/// @notice Base network fork test validating DisableV2Base spell execution and post-spell V2/V3 state
/// @dev Validates both JTRSY and JAAA V2 vault permissions are properly disabled
/// @dev Also tests V3 JAAA vault deployment on Base spoke
contract ForkTestPostSpellV2DisableBase is ForkTestPostSpellV2DisableCommon {
    // Expected V3 JAAA vault address (moved from spell for testing verification)
    address constant V3_JAAA_USDC_VAULT = 0x2AEf271F00A9d1b0DA8065D396f4E601dBD0Ef0b;
    function _rpcEndpoint() internal pure override returns (string memory) {
        return IntegrationConstants.RPC_BASE;
    }

    function _createSpell() internal override returns (DisableV2Common) {
        return new DisableV2Base();
    }

    function _configureNetwork() internal override {
        localCentrifugeId = _centrifugeId();
        adminSafe = _adminSafe();

        // Ensure JAAA pool exists on Base spoke (simulates notifyPool from Ethereum)
        _ensureJaaaPoolExists();
    }

    /// @notice Ensure JAAA pool exists on Base spoke before spell execution
    /// @dev Simulates the notifyPool message that would come from Ethereum Hub
    function _ensureJaaaPoolExists() internal {
        DisableV2Base baseSpell = new DisableV2Base();
        PoolId jaaaPoolId = baseSpell.JAAA_POOL_ID();

        ISpoke spoke = ISpoke(IntegrationConstants.SPOKE);

        // Check if pool already exists
        if (!spoke.isPoolActive(jaaaPoolId)) {
            // Add pool to spoke (simulates cross-chain notifyPool)
            ISpokeGatewayHandler spokeHandler = ISpokeGatewayHandler(IntegrationConstants.SPOKE);
            vm.prank(IntegrationConstants.BASE_ADMIN_SAFE);
            spokeHandler.addPool(jaaaPoolId);
        }
    }

    // Non-Ethereum networks don't have hub == spoke chain vaults
    function _canTestAsyncFlow() internal pure override returns (bool) {
        return false;
    }

    function _validateV2OperationsDisabled() internal override {
        _validateV2VaultOperationsFail(_jtrsyVaultAddress());
        _validateV2VaultOperationsFail(_jaaaVaultAddress());
    }

    function _validatePostSpellPermissions() internal view override {
        super._validatePostSpellPermissions();
        _validateVaultPermissions(_jtrsyVaultAddress(), spell.JTRSY_SHARE_TOKEN(), "JTRSY");

        DisableV2Base baseSpell = DisableV2Base(address(spell));
        _validateVaultPermissions(_jaaaVaultAddress(), baseSpell.JAAA_SHARE_TOKEN(), "JAAA");

        _validateJaaaV3Deployment();
    }

    function _jaaaVaultAddress() internal view returns (address) {
        return DisableV2Base(address(spell)).V2_JAAA_VAULT_ADDRESS();
    }

    function _centrifugeId() internal pure override returns (uint16) {
        return IntegrationConstants.BASE_CENTRIFUGE_ID;
    }

    function _adminSafe() internal pure override returns (address) {
        return IntegrationConstants.BASE_ADMIN_SAFE;
    }

    function _jtrsyVaultAddress() internal view override returns (address) {
        return DisableV2Base(address(spell)).V2_JTRSY_VAULT_ADDRESS();
    }

    /// @notice Validate JAAA V3 vault deployment and all related storage changes
    function _validateJaaaV3Deployment() internal view {
        DisableV2Base baseSpell = DisableV2Base(address(spell));

        _validateJaaaShareTokenWards(baseSpell);

        _validateSpokeDeploymentChanges(baseSpell);

        assertEq(
            AsyncRequestManagerV3_0_1Like(baseSpell.V3_ASYNC_REQUEST_MANAGER()).vault(
                baseSpell.JAAA_POOL_ID(), baseSpell.JAAA_SHARE_CLASS_ID(), baseSpell.V3_BASE_USDC_ASSET_ID()
            ),
            V3_JAAA_USDC_VAULT,
            "AsyncRequestManager vault mapping should point to correct V3 JAAA vault"
        );

        _validateShareTokenVaultMapping(baseSpell);
        _validateDeployedV3Vault(baseSpell);
    }

    /// @notice Validate JAAA share token has correct ward permissions
    function _validateJaaaShareTokenWards(DisableV2Base baseSpell) internal view {
        IShareToken jaaaShareToken = baseSpell.JAAA_SHARE_TOKEN();

        assertEq(
            IAuth(address(jaaaShareToken)).wards(address(spell.V3_ROOT())),
            1,
            "JAAA share token should have V3_ROOT as ward"
        );
        assertEq(
            IAuth(address(jaaaShareToken)).wards(baseSpell.V3_BALANCE_SHEET()),
            1,
            "JAAA share token should have V3_BALANCE_SHEET as ward"
        );
        assertEq(
            IAuth(address(jaaaShareToken)).wards(address(spell.V3_SPOKE())),
            1,
            "JAAA share token should have V3_SPOKE as ward"
        );
    }

    /// @notice Validate spoke storage changes from vault deployment
    function _validateSpokeDeploymentChanges(DisableV2Base baseSpell) internal view {
        ISpoke spoke = ISpoke(IntegrationConstants.SPOKE);
        PoolId poolId = baseSpell.JAAA_POOL_ID();
        ShareClassId shareClassId = baseSpell.JAAA_SHARE_CLASS_ID();

        IShareToken linkedShareToken = spoke.shareToken(poolId, shareClassId);
        assertEq(
            address(linkedShareToken),
            address(baseSpell.JAAA_SHARE_TOKEN()),
            "JAAA share token should be linked to pool/share class in spoke"
        );

        assertTrue(spoke.isPoolActive(poolId), "JAAA pool should be active on spoke");

        assertTrue(
            spoke.isLinked(IVault(V3_JAAA_USDC_VAULT)),
            "Deployed V3 JAAA vault should be marked as linked in spoke"
        );
    }

    /// @notice Validate share token vault mapping points to V3 vault
    function _validateShareTokenVaultMapping(DisableV2Base baseSpell) internal view {
        IShareToken jaaaShareToken = baseSpell.JAAA_SHARE_TOKEN();
        (address baseUsdcAddress,) = ISpoke(IntegrationConstants.SPOKE).idToAsset(baseSpell.V3_BASE_USDC_ASSET_ID());

        // JAAA share token's vault(BASE_USDC) should point to deployed V3 vault
        address vaultFromShareToken = jaaaShareToken.vault(baseUsdcAddress);
        assertTrue(
            vaultFromShareToken != address(0), "JAAA share token vault mapping should point to deployed V3 vault"
        );

        // Verify it has code (is deployed)
        assertTrue(vaultFromShareToken.code.length > 0, "V3 JAAA vault should have deployed code");
    }

    /// @notice Validate the deployed V3 vault has correct configuration
    function _validateDeployedV3Vault(DisableV2Base baseSpell) internal view {
        IShareToken jaaaShareToken = baseSpell.JAAA_SHARE_TOKEN();

        // Get vault address from share token mapping
        (address baseUsdcAddress,) = ISpoke(IntegrationConstants.SPOKE).idToAsset(baseSpell.V3_BASE_USDC_ASSET_ID());
        address v3VaultAddress = jaaaShareToken.vault(baseUsdcAddress);

        assertTrue(v3VaultAddress != address(0), "V3 JAAA vault should exist");

        IBaseVault v3Vault = IBaseVault(v3VaultAddress);
        assertEq(v3Vault.share(), address(jaaaShareToken), "V3 JAAA vault should have JAAA share token as its share");

        assertEq(
            PoolId.unwrap(v3Vault.poolId()),
            PoolId.unwrap(baseSpell.JAAA_POOL_ID()),
            "V3 JAAA vault should have correct pool ID"
        );

        assertEq(
            ShareClassId.unwrap(v3Vault.scId()),
            ShareClassId.unwrap(baseSpell.JAAA_SHARE_CLASS_ID()),
            "V3 JAAA vault should have correct share class ID"
        );
    }
}
