// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ForkTestPostSpellV2DisableCommon} from "./ForkTestPostSpellV2DisableCommon.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {ISpokeGatewayHandler} from "../../../src/common/interfaces/IGatewayHandlers.sol";

import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";

import {DisableV2Base} from "../../spell/DisableV2Base.sol";
import {DisableV2Common} from "../../spell/DisableV2Common.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

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
    function _canTestLocalAsyncFlow() internal pure override returns (bool) {
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

    /// @notice Validate JAAA V3 vault deployment using generalized validation functions
    function _validateJaaaV3Deployment() internal view {
        DisableV2Base baseSpell = DisableV2Base(address(spell));

        // Use generalized validation function from Common
        _validateV3ShareTokenDeployment(
            baseSpell.JAAA_SHARE_TOKEN(),
            baseSpell.JAAA_POOL_ID(),
            baseSpell.JAAA_SHARE_CLASS_ID(),
            baseSpell.V3_BASE_USDC_ASSET_ID(),
            V3_JAAA_USDC_VAULT,
            baseSpell.V3_ASYNC_REQUEST_MANAGER(),
            baseSpell.V3_BALANCE_SHEET(),
            "JAAA"
        );
    }

    /// @notice Override async tests to use complete cross-chain simulation flows
    function test_completeAsyncDepositLocalFlow() public override {
        completeAsyncDepositCrossChain(V3_JAAA_USDC_VAULT);
    }

    function test_completeAsyncRedeemLocalFlow() public override {
        completeAsyncRedeemCrossChain(V3_JAAA_USDC_VAULT);
    }
}
