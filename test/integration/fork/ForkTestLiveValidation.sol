// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestBase} from "./ForkTestBase.sol";
import {IV3_0_1_AsyncRequestManager, IV3_0_1_Spoke, IV3_0_1_ShareToken} from "./interfaces/IV3_0_1_Interfaces.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Hub} from "../../../src/core/hub/Hub.sol";
import {Spoke} from "../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../src/core/hub/HubHandler.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/core/spoke/interfaces/IVault.sol";
import {BalanceSheet} from "../../../src/core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {IRequestManager} from "../../../src/core/interfaces/IRequestManager.sol";
import {MessageProcessor} from "../../../src/core/messaging/MessageProcessor.sol";
import {IBalanceSheet} from "../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";
import {IVaultRegistry} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";

import {Root} from "../../../src/admin/Root.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../src/vaults/BatchRequestManager.sol";

import {NonCoreReport as MainContracts} from "../../../script/FullDeployer.s.sol";

import {VMLabeling} from "../utils/VMLabeling.sol";
import {ChainConfigs} from "../utils/ChainConfigs.sol";
import {AxelarAdapter} from "../../../src/adapters/AxelarAdapter.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {WormholeAdapter} from "../../../src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "../../../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../../../src/utils/RefundEscrowFactory.sol";

/// @title ForkTestLiveValidation
/// @notice Contract for validating live contract permissions and state
contract ForkTestLiveValidation is ForkTestBase, VMLabeling {
    using CastLib for *;

    uint8 constant PLUME_QUORUM = 1;
    uint8 constant STANDARD_QUORUM = 2;
    uint256 constant SUPPORTED_CHAINS_COUNT = 6;

    //----------------------------------------------------------------------------------------------
    // NON-ENV STATE (admin safe, vault/share token addresses)
    //----------------------------------------------------------------------------------------------

    // Admin
    address public protocolSafe;

    //----------------------------------------------------------------------------------------------
    // VAULT CONTRACTS (Chain-specific, populated in _initializeContractAddresses)
    //----------------------------------------------------------------------------------------------

    // Ethereum
    address public ethJaaaVault;
    address public ethJtrsyVault;
    address public ethDejaaaVault;
    address public ethDejtrsyVault;
    address public ethDejtrsyJtrsyVaultA;
    address public ethDejaaJaaaVaultA;
    address public ethDistrictUsdcVault;

    // Base
    address public baseJaaaUsdcVault;
    address public baseDejaaaUsdcVault;
    address public baseDejaaaJaaaVault;
    address public baseSpxaUsdcVault;

    // Avalanche
    address public avaxJaaaVault;
    address public avaxJaaaUsdcVault;
    address public avaxDejtrsyUsdcVault;
    address public avaxDejtrsyJtrsyVault;
    address public avaxJtrsyUsdcVault;
    address public avaxDejaaaUsdcVault;
    address public avaxDejaaaVault;

    // Arbitrum
    address public arbitrumJtrsyUsdcVault;
    address public arbitrumDejaaaUsdcVault;

    // BNB
    address public bnbJtrsyUsdcVault;
    address public bnbJaaaUsdcVault;

    // Plume
    address public plumeSyncDepositVault;
    address public plumeAcrdxUsdcVault;
    address public plumeJtrsyUsdcVault;

    //----------------------------------------------------------------------------------------------
    // SHARE TOKEN CONTRACTS (Chain-specific, populated in _initializeContractAddresses)
    //----------------------------------------------------------------------------------------------

    // Ethereum
    address public ethJaaaShareToken;
    address public ethJtrsyShareToken;
    address public ethDejtrsyShareToken;
    address public ethDejaaaShareToken;
    address public ethDistrictShareToken;

    // Base
    address public baseJaaaShareToken;
    address public baseJtrsyShareToken;
    address public baseDejaaaShareToken;
    address public baseDejtrsyShareToken;
    address public baseSpxaShareToken;

    // Arbitrum
    address public arbitrumJtrsyShareToken;
    address public arbitrumDejaaaShareToken;
    address public arbitrumDejtrsyShareToken;

    // Avalanche
    address public avaxJaaaShareToken;
    address public avaxJtrsyShareToken;
    address public avaxDejaaaShareToken;
    address public avaxDejtrsyShareToken;

    // BNB
    address public bnbJaaaShareToken;
    address public bnbJtrsyShareToken;

    // Plume
    address public plumeJtrsyShareToken;
    address public plumeAcrdxShareToken;
    address public plumeTestShareToken;

    //----------------------------------------------------------------------------------------------
    // SETUP
    //----------------------------------------------------------------------------------------------

    function setUp() public virtual override {
        super.setUp();
        _initializeContractAddresses();
        _setupVMLabels();
    }

    /// @notice Configure chain-specific settings
    /// @param protocolSafe_ The admin safe address for this chain
    /// @param centrifugeId_ The centrifuge chain ID
    function _configureChain(address protocolSafe_, uint16 centrifugeId_) public {
        config.network.centrifugeId = centrifugeId_;
        protocolSafe = protocolSafe_;
    }

    /// @notice Detects if the deployment is v3.1 or v3.0.1
    function isV3_1() internal view returns (bool) {
        return config.contracts.vaultRegistry != address(0) && config.contracts.vaultRegistry.code.length > 0;
    }

    /// @notice Helper function to determine if current chain is Ethereum
    function isEthereum() internal view returns (bool) {
        return config.network.centrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID;
    }

    /// @notice Initialize vault/share token addresses from IntegrationConstants
    function _initializeContractAddresses() public virtual {
        // Vault contracts (chain-specific)
        // Ethereum
        ethJaaaVault = IntegrationConstants.ETH_JAAA_VAULT;
        ethJtrsyVault = IntegrationConstants.ETH_JTRSY_VAULT;
        ethDejaaaVault = IntegrationConstants.ETH_DEJAA_USDC_VAULT;
        ethDejtrsyVault = IntegrationConstants.ETH_DEJTRSY_USDC_VAULT;
        ethDejtrsyJtrsyVaultA = IntegrationConstants.ETH_DEJTRSY_JTRSY_VAULT_A;
        ethDejaaJaaaVaultA = IntegrationConstants.ETH_DEJAA_JAAA_VAULT_A;
        ethDistrictUsdcVault = IntegrationConstants.ETH_DISTRICT_USDC_VAULT;

        // Base
        baseJaaaUsdcVault = IntegrationConstants.BASE_JAAA_USDC_VAULT;
        baseDejaaaUsdcVault = IntegrationConstants.BASE_DEJAAA_USDC_VAULT;
        baseDejaaaJaaaVault = IntegrationConstants.BASE_DEJAAA_JAAA_VAULT;
        baseSpxaUsdcVault = IntegrationConstants.BASE_SPXA_USDC_VAULT;

        // Avalanche
        avaxJaaaVault = IntegrationConstants.AVAX_JAAA_USDC_VAULT;
        avaxJaaaUsdcVault = IntegrationConstants.AVAX_JAAA_USDC_VAULT;
        avaxDejtrsyUsdcVault = IntegrationConstants.AVAX_DEJTRSY_USDC_VAULT;
        avaxDejtrsyJtrsyVault = IntegrationConstants.AVAX_DEJTRSY_JTRSY_VAULT;
        avaxJtrsyUsdcVault = IntegrationConstants.AVAX_JTRSY_USDC_VAULT;
        avaxDejaaaUsdcVault = IntegrationConstants.AVAX_DEJAAA_USDC_VAULT;
        avaxDejaaaVault = IntegrationConstants.AVAX_DEJAAA_VAULT;

        // Arbitrum
        arbitrumJtrsyUsdcVault = IntegrationConstants.ARBITRUM_JTRSY_USDC_VAULT;
        arbitrumDejaaaUsdcVault = IntegrationConstants.ARBITRUM_DEJAAA_USDC_VAULT;

        // BNB
        bnbJtrsyUsdcVault = IntegrationConstants.BNB_JTRSY_USDC_VAULT;
        bnbJaaaUsdcVault = IntegrationConstants.BNB_JAAA_USDC_VAULT;

        // Plume
        plumeSyncDepositVault = IntegrationConstants.PLUME_SYNC_DEPOSIT_VAULT;
        plumeAcrdxUsdcVault = IntegrationConstants.PLUME_ACRDX_USDC_VAULT;
        plumeJtrsyUsdcVault = IntegrationConstants.PLUME_JTRSY_USDC_VAULT;

        // Share token contracts (chain-specific)
        // Ethereum
        ethJaaaShareToken = IntegrationConstants.ETH_JAAA_SHARE_TOKEN;
        ethJtrsyShareToken = IntegrationConstants.ETH_JTRSY_SHARE_TOKEN;
        ethDejtrsyShareToken = IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN;
        ethDejaaaShareToken = IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN;
        ethDistrictShareToken = IntegrationConstants.ETH_DISTRICT_SHARE_TOKEN;

        // Base
        baseJaaaShareToken = IntegrationConstants.BASE_JAAA_SHARE_TOKEN;
        baseJtrsyShareToken = IntegrationConstants.BASE_JTRSY_SHARE_TOKEN;
        baseDejaaaShareToken = IntegrationConstants.BASE_DEJAAA_SHARE_TOKEN;
        baseDejtrsyShareToken = IntegrationConstants.BASE_DEJTRSY_SHARE_TOKEN;
        baseSpxaShareToken = IntegrationConstants.BASE_SPXA_SHARE_TOKEN;

        // Arbitrum
        arbitrumJtrsyShareToken = IntegrationConstants.ARBITRUM_JTRSY_SHARE_TOKEN;
        arbitrumDejaaaShareToken = IntegrationConstants.ARBITRUM_DEJAAA_SHARE_TOKEN;
        arbitrumDejtrsyShareToken = IntegrationConstants.ARBITRUM_DEJTRSY_SHARE_TOKEN;

        // Avalanche
        avaxJaaaShareToken = IntegrationConstants.AVAX_JAAA_SHARE_TOKEN;
        avaxJtrsyShareToken = IntegrationConstants.AVAX_JTRSY_SHARE_TOKEN;
        avaxDejaaaShareToken = IntegrationConstants.AVAX_DEJAAA_SHARE_TOKEN;
        avaxDejtrsyShareToken = IntegrationConstants.AVAX_DEJTRSY_SHARE_TOKEN;

        // BNB
        bnbJaaaShareToken = IntegrationConstants.BNB_JAAA_SHARE_TOKEN;
        bnbJtrsyShareToken = IntegrationConstants.BNB_JTRSY_SHARE_TOKEN;

        // Plume
        plumeJtrsyShareToken = IntegrationConstants.PLUME_JTRSY_SHARE_TOKEN;
        plumeAcrdxShareToken = IntegrationConstants.PLUME_ACRDX_SHARE_TOKEN;
        plumeTestShareToken = IntegrationConstants.PLUME_TEST_SHARE_TOKEN;

        // Admin safe (default for standalone tests)
        protocolSafe = IntegrationConstants.ETH_ADMIN_SAFE;
    }

    /// @notice Load contract addresses from a FullDeployer instance (for pre-migration testing)
    /// @dev Alternative to env config loading when testing fresh deployments
    ///      Use this when validating a freshly deployed v3.1 system in fork (e.g., MigrationV3_1Test)
    /// @param report The MainContracts instance that comes from the deployed v3.1 contracts
    function loadContractsFromDeployer(MainContracts memory report, address protocolSafe_) public virtual {
        // Core system contracts
        config.contracts.root = address(report.core.root);
        config.contracts.protocolGuardian = address(report.core.protocolGuardian);
        config.contracts.opsGuardian = address(report.core.opsGuardian);
        config.contracts.gateway = address(report.core.gateway);
        config.contracts.gasService = address(report.core.gasService);
        config.contracts.tokenRecoverer = address(report.core.tokenRecoverer);
        config.contracts.messageProcessor = address(report.core.messageProcessor);
        config.contracts.messageDispatcher = address(report.core.messageDispatcher);
        config.contracts.multiAdapter = address(report.core.multiAdapter);

        // Hub contracts
        config.contracts.hubRegistry = address(report.core.hubRegistry);
        config.contracts.accounting = address(report.core.accounting);
        config.contracts.holdings = address(report.core.holdings);
        config.contracts.shareClassManager = address(report.core.shareClassManager);
        config.contracts.hub = address(report.core.hub);
        config.contracts.hubHandler = address(report.core.hubHandler);
        config.contracts.batchRequestManager = address(report.batchRequestManager);
        config.contracts.identityValuation = address(report.identityValuation);

        // Spoke contracts
        config.contracts.tokenFactory = address(report.core.tokenFactory);
        config.contracts.balanceSheet = address(report.core.balanceSheet);
        config.contracts.spoke = address(report.core.spoke);
        config.contracts.vaultRegistry = address(report.core.vaultRegistry);
        config.contracts.contractUpdater = address(report.core.contractUpdater);
        config.contracts.poolEscrowFactory = address(report.core.poolEscrowFactory);

        // Vault system
        config.contracts.vaultRouter = address(report.vaultRouter);
        config.contracts.asyncRequestManager = address(report.asyncRequestManager);
        config.contracts.syncManager = address(report.syncManager);
        config.contracts.refundEscrowFactory = address(report.refundEscrowFactory);
        config.contracts.subsidyManager = address(report.subsidyManager);

        // Skip wormholeAdapter, axelarAdapter, layerZeroAdapter due to not being public in FullDeployer
        // Can be queried via multiAdapter.adapters()

        // Factory contracts
        config.contracts.asyncVaultFactory = address(report.asyncVaultFactory);
        config.contracts.syncDepositVaultFactory = address(report.syncDepositVaultFactory);

        // Hook contracts
        config.contracts.freezeOnlyHook = address(report.freezeOnlyHook);
        config.contracts.fullRestrictionsHook = address(report.fullRestrictionsHook);
        config.contracts.freelyTransferableHook = address(report.freelyTransferableHook);
        config.contracts.redemptionRestrictionsHook = address(report.redemptionRestrictionsHook);

        // Multichain config - from deployed contracts
        config.network.centrifugeId = report.core.messageDispatcher.localCentrifugeId();
        protocolSafe = protocolSafe_;
    }

    /// @notice Setup VM labels for debugging
    function _setupVMLabels() internal virtual override {
        // Call parent VMLabeling to label all IntegrationConstants
        super._setupVMLabels();

        // Additional labels for instance variables (if they differ from constants)
        vm.label(config.contracts.root, "Root");
        vm.label(config.contracts.protocolGuardian, "ProtocolGuardian");
        vm.label(config.contracts.gateway, "Gateway");
        vm.label(config.contracts.gasService, "GasService");
        vm.label(config.contracts.tokenRecoverer, "TokenRecoverer");
        vm.label(config.contracts.messageProcessor, "MessageProcessor");
        vm.label(config.contracts.messageDispatcher, "MessageDispatcher");
        vm.label(config.contracts.multiAdapter, "MultiAdapter");
        vm.label(config.contracts.hubRegistry, "HubRegistry");
        vm.label(config.contracts.accounting, "Accounting");
        vm.label(config.contracts.holdings, "Holdings");
        vm.label(config.contracts.shareClassManager, "ShareClassManager");
        vm.label(config.contracts.hub, "Hub");
        vm.label(config.contracts.identityValuation, "IdentityValuation");
        vm.label(config.contracts.tokenFactory, "TokenFactory");
        vm.label(config.contracts.balanceSheet, "BalanceSheet");
        vm.label(config.contracts.spoke, "Spoke");
        vm.label(config.contracts.contractUpdater, "ContractUpdater");
        vm.label(config.contracts.poolEscrowFactory, "PoolEscrowFactory");
        vm.label(config.contracts.vaultRouter, "VaultRouter");
        vm.label(config.contracts.asyncRequestManager, "AsyncRequestManager");
        vm.label(config.contracts.syncManager, "SyncManager");
        vm.label(config.contracts.wormholeAdapter, "WormholeAdapter");
        vm.label(config.contracts.axelarAdapter, "AxelarAdapter");
        vm.label(config.contracts.asyncVaultFactory, "AsyncVaultFactory");
        vm.label(config.contracts.syncDepositVaultFactory, "SyncDepositVaultFactory");
        vm.label(config.contracts.freezeOnlyHook, "FreezeOnlyHook");
        vm.label(config.contracts.fullRestrictionsHook, "FullRestrictionsHook");
        vm.label(config.contracts.freelyTransferableHook, "FreelyTransferableHook");
        vm.label(config.contracts.redemptionRestrictionsHook, "RedemptionRestrictionsHook");
    }

    //----------------------------------------------------------------------------------------------
    // VALIDATION ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function test_validateCompleteDeployment() public virtual {
        vm.skip(true); // Skip until v3.1 is deployed - v3.0.1 has different ward relationships
        if (config.network.centrifugeId == 0) {
            _configureChain(IntegrationConstants.ETH_ADMIN_SAFE, IntegrationConstants.ETH_CENTRIFUGE_ID);
        }
        validateDeployment(false);
    }

    /// @notice Validates wards, file() configurations, endorsements, adapter configs, vaults & share tokens
    /// @param preMigration If true, skips validations that only apply post-migration (root wards, endorsements, vaults, sender configs)
    function validateDeployment(bool preMigration) public view virtual {
        validateDeployment(preMigration, true);
    }

    /// @notice Validates wards, file() configurations, endorsements, adapter configs, vaults & share tokens
    /// @param preMigration If true, skips validations that only apply post-migration (root wards, endorsements, vaults, sender configs)
    /// @param isMainnet If true, validates production vaults. Set to false for testnets which have different assets/vaults.
    function validateDeployment(bool preMigration, bool isMainnet) public view virtual {
        _validateV3RootPermissions();
        _validateContractWardRelationships(preMigration);
        _validateFileConfigurations(preMigration);

        // Only validate adapters if they're deployed and wired
        // Adapter wiring is handled separately from state migration in production
        if (_shouldValidateAdapters()) {
            _validateGuardianAdapterConfigurations();
            _validateAdapterSourceDestinationMappings();
        }

        // Endorsements and vaults are only validated post v3.1 migration
        if (!preMigration) {
            _validateEndorsements();
            if (isMainnet) {
                _validateVaults();
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // ROOT PERMISSIONS VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates that all deployed contracts have Root as a ward
    function _validateV3RootPermissions() internal view virtual {
        // From CoreDeployer - Core messaging
        _validateRootWard(config.contracts.gateway);
        _validateRootWard(config.contracts.multiAdapter);
        _validateRootWard(config.contracts.messageDispatcher);
        _validateRootWard(config.contracts.messageProcessor);

        // From CoreDeployer - Spoke contracts
        _validateRootWard(config.contracts.poolEscrowFactory);
        _validateRootWard(config.contracts.tokenFactory);
        _validateRootWard(config.contracts.spoke);
        _validateRootWard(config.contracts.balanceSheet);
        _validateRootWard(config.contracts.contractUpdater);
        if (config.contracts.vaultRegistry != address(0)) _validateRootWard(config.contracts.vaultRegistry);

        // From CoreDeployer - Hub contracts
        _validateRootWard(config.contracts.hubRegistry);
        _validateRootWard(config.contracts.accounting);
        _validateRootWard(config.contracts.holdings);
        _validateRootWard(config.contracts.shareClassManager);
        _validateRootWard(config.contracts.hub);
        if (config.contracts.hubHandler != address(0)) _validateRootWard(config.contracts.hubHandler);

        // From FullDeployer - Admin & escrows
        _validateRootWard(config.contracts.tokenRecoverer);
        if (config.contracts.refundEscrowFactory != address(0)) {
            _validateRootWard(config.contracts.refundEscrowFactory);
        }

        // From FullDeployer - Vault system
        _validateRootWard(config.contracts.asyncVaultFactory);
        _validateRootWard(config.contracts.asyncRequestManager);
        _validateRootWard(config.contracts.syncDepositVaultFactory);
        _validateRootWard(config.contracts.syncManager);
        _validateRootWard(config.contracts.vaultRouter);

        // From FullDeployer - Hooks
        _validateRootWard(config.contracts.freezeOnlyHook);
        _validateRootWard(config.contracts.fullRestrictionsHook);
        _validateRootWard(config.contracts.freelyTransferableHook);
        _validateRootWard(config.contracts.redemptionRestrictionsHook);

        // From FullDeployer - Batch request manager
        if (config.contracts.batchRequestManager != address(0)) {
            _validateRootWard(config.contracts.batchRequestManager);
        }

        // From FullDeployer - Adapters
        if (config.contracts.wormholeAdapter != address(0)) _validateRootWard(config.contracts.wormholeAdapter);
        if (config.contracts.axelarAdapter != address(0)) _validateRootWard(config.contracts.axelarAdapter);
        if (config.contracts.layerZeroAdapter != address(0)) _validateRootWard(config.contracts.layerZeroAdapter);

        // Chain-specific vaults and share tokens
        if (isEthereum()) {
            if (ethJaaaVault != address(0)) _validateRootWard(ethJaaaVault);
            if (ethJtrsyVault != address(0)) _validateRootWard(ethJtrsyVault);
            if (ethDejaaaVault != address(0)) _validateRootWard(ethDejaaaVault);
            if (ethDejtrsyVault != address(0)) _validateRootWard(ethDejtrsyVault);
            if (ethDejtrsyJtrsyVaultA != address(0)) _validateRootWard(ethDejtrsyJtrsyVaultA);
            if (ethDejaaJaaaVaultA != address(0)) _validateRootWard(ethDejaaJaaaVaultA);
            if (ethDistrictUsdcVault != address(0)) _validateRootWard(ethDistrictUsdcVault);

            if (ethJaaaShareToken != address(0)) _validateRootWard(ethJaaaShareToken);
            if (ethJtrsyShareToken != address(0)) _validateRootWard(ethJtrsyShareToken);
            if (ethDejtrsyShareToken != address(0)) _validateRootWard(ethDejtrsyShareToken);
            if (ethDejaaaShareToken != address(0)) _validateRootWard(ethDejaaaShareToken);
        } else if (config.network.centrifugeId == IntegrationConstants.BASE_CENTRIFUGE_ID) {
            if (baseJaaaUsdcVault != address(0)) _validateRootWard(baseJaaaUsdcVault);
            if (baseDejaaaUsdcVault != address(0)) _validateRootWard(baseDejaaaUsdcVault);
            if (baseDejaaaJaaaVault != address(0)) _validateRootWard(baseDejaaaJaaaVault);
            if (baseSpxaUsdcVault != address(0)) _validateRootWard(baseSpxaUsdcVault);

            if (baseJaaaShareToken != address(0)) _validateRootWard(baseJaaaShareToken);
            if (baseJtrsyShareToken != address(0)) _validateRootWard(baseJtrsyShareToken);
            if (baseDejaaaShareToken != address(0)) _validateRootWard(baseDejaaaShareToken);
            if (baseDejtrsyShareToken != address(0)) _validateRootWard(baseDejtrsyShareToken);
            if (baseSpxaShareToken != address(0)) _validateRootWard(baseSpxaShareToken);
        } else if (config.network.centrifugeId == IntegrationConstants.ARBITRUM_CENTRIFUGE_ID) {
            if (arbitrumJtrsyShareToken != address(0)) _validateRootWard(arbitrumJtrsyShareToken);
            if (arbitrumDejaaaShareToken != address(0)) _validateRootWard(arbitrumDejaaaShareToken);
            if (arbitrumDejtrsyShareToken != address(0)) _validateRootWard(arbitrumDejtrsyShareToken);
        } else if (config.network.centrifugeId == IntegrationConstants.AVAX_CENTRIFUGE_ID) {
            if (avaxJaaaVault != address(0)) _validateRootWard(avaxJaaaVault);
            if (avaxJaaaUsdcVault != address(0)) _validateRootWard(avaxJaaaUsdcVault);
            if (avaxDejtrsyUsdcVault != address(0)) _validateRootWard(avaxDejtrsyUsdcVault);
            if (avaxDejtrsyJtrsyVault != address(0)) _validateRootWard(avaxDejtrsyJtrsyVault);
            if (avaxJtrsyUsdcVault != address(0)) _validateRootWard(avaxJtrsyUsdcVault);
            if (avaxDejaaaUsdcVault != address(0)) _validateRootWard(avaxDejaaaUsdcVault);
            if (avaxDejaaaVault != address(0)) _validateRootWard(avaxDejaaaVault);

            if (avaxJaaaShareToken != address(0)) _validateRootWard(avaxJaaaShareToken);
            if (avaxJtrsyShareToken != address(0)) _validateRootWard(avaxJtrsyShareToken);
            if (avaxDejaaaShareToken != address(0)) _validateRootWard(avaxDejaaaShareToken);
            if (avaxDejtrsyShareToken != address(0)) _validateRootWard(avaxDejtrsyShareToken);
        } else if (config.network.centrifugeId == IntegrationConstants.BNB_CENTRIFUGE_ID) {
            if (bnbJaaaShareToken != address(0)) _validateRootWard(bnbJaaaShareToken);
            if (bnbJtrsyShareToken != address(0)) _validateRootWard(bnbJtrsyShareToken);
        } else if (config.network.centrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            if (plumeSyncDepositVault != address(0)) _validateRootWard(plumeSyncDepositVault);

            if (plumeJtrsyShareToken != address(0)) _validateRootWard(plumeJtrsyShareToken);
            if (plumeAcrdxShareToken != address(0)) _validateRootWard(plumeAcrdxShareToken);
        }
    }

    /// @notice Helper to validate a contract has Root as ward
    function _validateRootWard(address contractAddr) internal view {
        require(
            contractAddr.code.length > 0, string(abi.encodePacked("Contract has no code: ", vm.toString(contractAddr)))
        );
        assertEq(
            IAuth(contractAddr).wards(config.contracts.root),
            1,
            string(abi.encodePacked("Root not ward of: ", vm.toString(contractAddr)))
        );
    }

    //----------------------------------------------------------------------------------------------
    // CONTRACT WARD RELATIONSHIPS VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates all contract-to-contract ward relationships
    /// @param skipNewRootChecks If true, skips validating wards on Root for newly deployed contracts (set post-migration)
    function _validateContractWardRelationships(bool skipNewRootChecks) internal view {
        // ==================== CORE MESSAGING (CoreDeployer) ====================

        if (!skipNewRootChecks) {
            _validateWard(config.contracts.root, config.contracts.messageProcessor);
            _validateWard(config.contracts.root, config.contracts.messageDispatcher);
        }

        _validateWard(config.contracts.multiAdapter, config.contracts.gateway);
        _validateWard(config.contracts.gateway, config.contracts.multiAdapter);
        _validateWard(config.contracts.gateway, config.contracts.messageDispatcher);
        // NOTE: gateway.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(config.contracts.gateway, config.contracts.messageProcessor);
        }
        _validateWard(config.contracts.gateway, config.contracts.spoke);

        _validateWard(config.contracts.messageProcessor, config.contracts.gateway);
        // NOTE: multiAdapter.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(config.contracts.multiAdapter, config.contracts.messageProcessor);
        }
        _validateWard(config.contracts.multiAdapter, config.contracts.hub);

        _validateWard(config.contracts.spoke, config.contracts.messageDispatcher);
        _validateWard(config.contracts.balanceSheet, config.contracts.messageDispatcher);
        _validateWard(config.contracts.contractUpdater, config.contracts.messageDispatcher);
        if (config.contracts.vaultRegistry != address(0)) {
            _validateWard(config.contracts.vaultRegistry, config.contracts.messageDispatcher);
        }
        if (config.contracts.hubHandler != address(0)) {
            _validateWard(config.contracts.hubHandler, config.contracts.messageDispatcher);
        }
        _validateWard(config.contracts.messageDispatcher, config.contracts.spoke);
        _validateWard(config.contracts.messageDispatcher, config.contracts.balanceSheet);
        _validateWard(config.contracts.messageDispatcher, config.contracts.hub);
        if (config.contracts.hubHandler != address(0)) {
            _validateWard(config.contracts.messageDispatcher, config.contracts.hubHandler);
        }

        // NOTE: gateway.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(config.contracts.gateway, config.contracts.messageProcessor);
        }
        _validateWard(config.contracts.spoke, config.contracts.messageProcessor);
        _validateWard(config.contracts.balanceSheet, config.contracts.messageProcessor);
        _validateWard(config.contracts.contractUpdater, config.contracts.messageProcessor);
        if (config.contracts.vaultRegistry != address(0)) {
            _validateWard(config.contracts.vaultRegistry, config.contracts.messageProcessor);
        }
        if (config.contracts.hubHandler != address(0)) {
            _validateWard(config.contracts.hubHandler, config.contracts.messageProcessor);
        }

        // ==================== SPOKE SIDE (CoreDeployer) ====================

        _validateWard(config.contracts.messageDispatcher, config.contracts.spoke);
        _validateWard(config.contracts.tokenFactory, config.contracts.spoke);
        _validateWard(config.contracts.poolEscrowFactory, config.contracts.spoke);
        if (config.contracts.vaultRegistry != address(0)) {
            _validateWard(config.contracts.spoke, config.contracts.vaultRegistry);
        }

        _validateWard(config.contracts.messageDispatcher, config.contracts.balanceSheet);

        // ==================== HUB SIDE (CoreDeployer) ====================

        _validateWard(config.contracts.accounting, config.contracts.hub);
        _validateWard(config.contracts.holdings, config.contracts.hub);
        _validateWard(config.contracts.hubRegistry, config.contracts.hub);
        _validateWard(config.contracts.shareClassManager, config.contracts.hub);
        _validateWard(config.contracts.messageDispatcher, config.contracts.hub);
        if (config.contracts.hubHandler != address(0)) {
            _validateWard(config.contracts.hub, config.contracts.hubHandler);
        }

        if (config.contracts.hubHandler != address(0)) {
            _validateWard(config.contracts.hubRegistry, config.contracts.hubHandler);
            _validateWard(config.contracts.holdings, config.contracts.hubHandler);
            _validateWard(config.contracts.shareClassManager, config.contracts.hubHandler);
            _validateWard(config.contracts.messageDispatcher, config.contracts.hubHandler);
        }

        // ==================== VAULT SIDE (FullDeployer) ====================

        _validateWard(config.contracts.asyncRequestManager, config.contracts.spoke);
        _validateWard(config.contracts.asyncRequestManager, config.contracts.contractUpdater);
        _validateWard(config.contracts.asyncRequestManager, config.contracts.asyncVaultFactory);
        _validateWard(config.contracts.asyncRequestManager, config.contracts.syncDepositVaultFactory);

        _validateWard(config.contracts.syncManager, config.contracts.contractUpdater);
        _validateWard(config.contracts.syncManager, config.contracts.syncDepositVaultFactory);

        if (config.contracts.vaultRegistry != address(0)) {
            _validateWard(config.contracts.asyncVaultFactory, config.contracts.vaultRegistry);
            _validateWard(config.contracts.syncDepositVaultFactory, config.contracts.vaultRegistry);
        }

        // ==================== HOOK (FullDeployer) ====================

        _validateWard(config.contracts.freezeOnlyHook, config.contracts.spoke);
        _validateWard(config.contracts.fullRestrictionsHook, config.contracts.spoke);
        _validateWard(config.contracts.freelyTransferableHook, config.contracts.spoke);
        _validateWard(config.contracts.redemptionRestrictionsHook, config.contracts.spoke);

        // ==================== BATCH REQUEST MANAGER (FullDeployer) ====================

        if (config.contracts.batchRequestManager != address(0)) {
            _validateWard(config.contracts.batchRequestManager, config.contracts.hub);
            if (config.contracts.hubHandler != address(0)) {
                _validateWard(config.contracts.batchRequestManager, config.contracts.hubHandler);
            }
        }

        // ==================== GUARDIAN (FullDeployer) ====================

        if (config.contracts.protocolGuardian != address(0)) {
            _validateWard(config.contracts.gateway, config.contracts.protocolGuardian);
            _validateWard(config.contracts.multiAdapter, config.contracts.protocolGuardian);
            _validateWard(config.contracts.messageDispatcher, config.contracts.protocolGuardian);
            if (!skipNewRootChecks) {
                _validateWard(config.contracts.root, config.contracts.protocolGuardian);
            }
            _validateWard(config.contracts.tokenRecoverer, config.contracts.protocolGuardian);
            if (config.contracts.wormholeAdapter != address(0)) {
                _validateWard(config.contracts.wormholeAdapter, config.contracts.protocolGuardian);
            }
            if (config.contracts.axelarAdapter != address(0)) {
                _validateWard(config.contracts.axelarAdapter, config.contracts.protocolGuardian);
            }
            if (config.contracts.layerZeroAdapter != address(0)) {
                _validateWard(config.contracts.layerZeroAdapter, config.contracts.protocolGuardian);
            }
        }

        if (config.contracts.opsGuardian != address(0)) {
            _validateWard(config.contracts.multiAdapter, config.contracts.opsGuardian);
            _validateWard(config.contracts.hub, config.contracts.opsGuardian);

            // Temporal wards for initial adapter wiring
            if (config.contracts.wormholeAdapter != address(0)) {
                _validateWard(config.contracts.wormholeAdapter, config.contracts.opsGuardian);
            }
            if (config.contracts.axelarAdapter != address(0)) {
                _validateWard(config.contracts.axelarAdapter, config.contracts.opsGuardian);
            }
            if (config.contracts.layerZeroAdapter != address(0)) {
                _validateWard(config.contracts.layerZeroAdapter, config.contracts.opsGuardian);
            }
        }

        if (config.contracts.layerZeroAdapter != address(0) && protocolSafe != address(0)) {
            _validateWard(config.contracts.layerZeroAdapter, protocolSafe);
        }

        // ==================== TOKEN RECOVERER (FullDeployer) ====================

        if (!skipNewRootChecks) {
            _validateWard(config.contracts.root, config.contracts.tokenRecoverer);
        }
        _validateWard(config.contracts.tokenRecoverer, config.contracts.messageDispatcher);
        _validateWard(config.contracts.tokenRecoverer, config.contracts.messageProcessor);
    }

    /// @notice Helper to validate a ward relationship
    function _validateWard(address wardedContract, address wardHolder) internal view {
        assertEq(
            IAuth(wardedContract).wards(wardHolder),
            1,
            string(abi.encodePacked(vm.toString(wardHolder), " not ward of ", vm.toString(wardedContract)))
        );
    }

    //----------------------------------------------------------------------------------------------
    // FILE CONFIGURATIONS VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates all file() pointer configurations
    /// @param preMigration If true, skips sender validations that are set by MigrationSpell (not CoreDeployer)
    function _validateFileConfigurations(bool preMigration) internal view virtual {
        // ==================== CORE MESSAGING (CoreDeployer) ====================

        assertEq(
            address(Gateway(payable(config.contracts.gateway)).adapter()),
            config.contracts.multiAdapter,
            "Gateway adapter mismatch"
        );
        assertEq(
            address(Gateway(payable(config.contracts.gateway)).messageProperties()),
            config.contracts.gasService,
            "Gateway messageProperties mismatch"
        );
        assertEq(
            address(Gateway(payable(config.contracts.gateway)).processor()),
            config.contracts.messageProcessor,
            "Gateway processor mismatch"
        );

        assertEq(
            address(MultiAdapter(config.contracts.multiAdapter).messageProperties()),
            config.contracts.gasService,
            "MultiAdapter messageProperties mismatch"
        );

        assertEq(
            address(MessageDispatcher(config.contracts.messageDispatcher).spoke()),
            config.contracts.spoke,
            "MessageDispatcher spoke mismatch"
        );
        assertEq(
            address(MessageDispatcher(config.contracts.messageDispatcher).balanceSheet()),
            config.contracts.balanceSheet,
            "MessageDispatcher balanceSheet mismatch"
        );
        assertEq(
            address(MessageDispatcher(config.contracts.messageDispatcher).contractUpdater()),
            config.contracts.contractUpdater,
            "MessageDispatcher contractUpdater mismatch"
        );
        assertEq(
            address(MessageDispatcher(config.contracts.messageDispatcher).tokenRecoverer()),
            config.contracts.tokenRecoverer,
            "MessageDispatcher tokenRecoverer mismatch"
        );
        if (config.contracts.vaultRegistry != address(0)) {
            assertEq(
                address(MessageDispatcher(config.contracts.messageDispatcher).vaultRegistry()),
                config.contracts.vaultRegistry,
                "MessageDispatcher vaultRegistry mismatch"
            );
        }
        if (config.contracts.hubHandler != address(0)) {
            assertEq(
                address(MessageDispatcher(config.contracts.messageDispatcher).hubHandler()),
                config.contracts.hubHandler,
                "MessageDispatcher hubHandler mismatch"
            );
        }

        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).multiAdapter()),
            config.contracts.multiAdapter,
            "MessageProcessor multiAdapter mismatch"
        );
        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).gateway()),
            config.contracts.gateway,
            "MessageProcessor gateway mismatch"
        );
        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).spoke()),
            config.contracts.spoke,
            "MessageProcessor spoke mismatch"
        );
        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).balanceSheet()),
            config.contracts.balanceSheet,
            "MessageProcessor balanceSheet mismatch"
        );
        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).contractUpdater()),
            config.contracts.contractUpdater,
            "MessageProcessor contractUpdater mismatch"
        );
        assertEq(
            address(MessageProcessor(config.contracts.messageProcessor).tokenRecoverer()),
            config.contracts.tokenRecoverer,
            "MessageProcessor tokenRecoverer mismatch"
        );
        if (config.contracts.vaultRegistry != address(0)) {
            assertEq(
                address(MessageProcessor(config.contracts.messageProcessor).vaultRegistry()),
                config.contracts.vaultRegistry,
                "MessageProcessor vaultRegistry mismatch"
            );
        }
        if (config.contracts.hubHandler != address(0)) {
            assertEq(
                address(MessageProcessor(config.contracts.messageProcessor).hubHandler()),
                config.contracts.hubHandler,
                "MessageProcessor hubHandler mismatch"
            );
        }

        // ==================== SPOKE SIDE (CoreDeployer) ====================

        assertEq(address(Spoke(config.contracts.spoke).gateway()), config.contracts.gateway, "Spoke gateway mismatch");
        assertEq(
            address(Spoke(config.contracts.spoke).poolEscrowFactory()),
            config.contracts.poolEscrowFactory,
            "Spoke poolEscrowFactory mismatch"
        );
        // NOTE: spoke.sender is set by MigrationSpell, not CoreDeployer (when reusing existing Root)
        if (!preMigration) {
            assertEq(
                address(Spoke(config.contracts.spoke).sender()),
                config.contracts.messageDispatcher,
                "Spoke sender mismatch"
            );
        }

        assertEq(
            address(BalanceSheet(config.contracts.balanceSheet).spoke()),
            config.contracts.spoke,
            "BalanceSheet spoke mismatch"
        );
        assertEq(
            address(BalanceSheet(config.contracts.balanceSheet).gateway()),
            config.contracts.gateway,
            "BalanceSheet gateway mismatch"
        );
        assertEq(
            address(BalanceSheet(config.contracts.balanceSheet).poolEscrowProvider()),
            config.contracts.poolEscrowFactory,
            "BalanceSheet poolEscrowProvider mismatch"
        );
        assertEq(
            address(BalanceSheet(config.contracts.balanceSheet).sender()),
            config.contracts.messageDispatcher,
            "BalanceSheet sender mismatch"
        );

        if (config.contracts.vaultRegistry != address(0)) {
            assertEq(
                address(VaultRegistry(config.contracts.vaultRegistry).spoke()),
                config.contracts.spoke,
                "VaultRegistry spoke mismatch"
            );
        }

        // ==================== HUB SIDE (CoreDeployer) ====================

        assertEq(address(Hub(config.contracts.hub).sender()), config.contracts.messageDispatcher, "Hub sender mismatch");

        if (config.contracts.hubHandler != address(0)) {
            assertEq(
                address(HubHandler(config.contracts.hubHandler).sender()),
                config.contracts.messageDispatcher,
                "HubHandler sender mismatch"
            );
        }

        // ==================== VAULT SIDE (FullDeployer) ====================

        if (config.contracts.refundEscrowFactory != address(0) && config.contracts.subsidyManager != address(0)) {
            assertEq(
                address(RefundEscrowFactory(config.contracts.refundEscrowFactory).controller()),
                config.contracts.subsidyManager,
                "RefundEscrowFactory controller mismatch"
            );
        }

        assertEq(
            address(AsyncRequestManager(payable(config.contracts.asyncRequestManager)).spoke()),
            config.contracts.spoke,
            "AsyncRequestManager spoke mismatch"
        );
        assertEq(
            address(AsyncRequestManager(payable(config.contracts.asyncRequestManager)).balanceSheet()),
            config.contracts.balanceSheet,
            "AsyncRequestManager balanceSheet mismatch"
        );
        if (config.contracts.vaultRegistry != address(0)) {
            assertEq(
                address(AsyncRequestManager(payable(config.contracts.asyncRequestManager)).vaultRegistry()),
                config.contracts.vaultRegistry,
                "AsyncRequestManager vaultRegistry mismatch"
            );
        }

        assertEq(
            address(SyncManager(config.contracts.syncManager).spoke()),
            config.contracts.spoke,
            "SyncManager spoke mismatch"
        );
        assertEq(
            address(SyncManager(config.contracts.syncManager).balanceSheet()),
            config.contracts.balanceSheet,
            "SyncManager balanceSheet mismatch"
        );
        if (config.contracts.vaultRegistry != address(0)) {
            assertEq(
                address(SyncManager(config.contracts.syncManager).vaultRegistry()),
                config.contracts.vaultRegistry,
                "SyncManager vaultRegistry mismatch"
            );
        }

        if (config.contracts.batchRequestManager != address(0)) {
            assertEq(
                address(BatchRequestManager(config.contracts.batchRequestManager).hub()),
                config.contracts.hub,
                "BatchRequestManager hub mismatch"
            );
        }

        // ==================== GUARDIAN  ====================

        if (config.contracts.opsGuardian != address(0)) {
            address opsSafeAddr = address(OpsGuardian(config.contracts.opsGuardian).opsSafe());
            assertTrue(opsSafeAddr != address(0), "OpsGuardian opsSafe not configured");
        }

        if (config.contracts.protocolGuardian != address(0) && protocolSafe != address(0)) {
            assertEq(
                address(ProtocolGuardian(config.contracts.protocolGuardian).safe()),
                protocolSafe,
                "ProtocolGuardian safe mismatch"
            );
        }
    }

    //----------------------------------------------------------------------------------------------
    // ENDORSEMENTS VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates Root endorsements
    function _validateEndorsements() internal view {
        assertTrue(
            Root(config.contracts.root).endorsed(config.contracts.balanceSheet), "BalanceSheet not endorsed by Root"
        );
        assertTrue(
            Root(config.contracts.root).endorsed(config.contracts.asyncRequestManager),
            "AsyncRequestManager not endorsed by Root"
        );
        assertTrue(
            Root(config.contracts.root).endorsed(config.contracts.vaultRouter), "VaultRouter not endorsed by Root"
        );
    }

    //----------------------------------------------------------------------------------------------
    // ADAPTER VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates MultiAdapter configurations for all connected chains (GLOBAL_POOL only)
    function _validateGuardianAdapterConfigurations() internal view virtual {
        MultiAdapter multiAdapterContract = MultiAdapter(config.contracts.multiAdapter);
        ChainConfigs.ChainConfig[SUPPORTED_CHAINS_COUNT] memory chains = ChainConfigs.getAllChains();
        PoolId globalPool = PoolId.wrap(0);

        // Validate MultiAdapter configuration for all connected chains based on network topology
        for (uint256 i = 0; i < chains.length; i++) {
            if (_shouldValidateChain(chains[i].centrifugeId)) {
                _validateMultiAdapterConfiguration(multiAdapterContract, chains[i].centrifugeId, globalPool, chains[i]);
            }
        }
    }

    /// @notice Validates adapter source and destination mappings based on network topology
    function _validateAdapterSourceDestinationMappings() internal view virtual {
        ChainConfigs.ChainConfig[SUPPORTED_CHAINS_COUNT] memory chains = ChainConfigs.getAllChains();

        for (uint256 i = 0; i < chains.length; i++) {
            if (_shouldValidateChain(chains[i].centrifugeId)) {
                // Always validate Wormhole mapping
                if (config.contracts.wormholeAdapter != address(0)) {
                    _validateWormholeMapping(
                        WormholeAdapter(config.contracts.wormholeAdapter),
                        chains[i].wormholeId,
                        chains[i].centrifugeId,
                        chains[i].name
                    );
                }

                // Validate Axelar mapping if both current chain and target chain support it
                if (
                    config.contracts.axelarAdapter != address(0)
                        && config.network.centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID
                        && chains[i].hasAxelar
                ) {
                    _validateAxelarMapping(
                        AxelarAdapter(config.contracts.axelarAdapter),
                        chains[i].axelarId,
                        chains[i].centrifugeId,
                        chains[i].name
                    );
                }

                // Validate LayerZero mapping if both current chain and target chain support it
                if (
                    config.contracts.layerZeroAdapter != address(0)
                        && config.network.centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID
                        && chains[i].hasLayerZero
                ) {
                    _validateLayerZeroMapping(
                        LayerZeroAdapter(config.contracts.layerZeroAdapter),
                        chains[i].layerZeroEid,
                        chains[i].centrifugeId,
                        chains[i].name
                    );
                }
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // HELPER FUNCTIONS
    //----------------------------------------------------------------------------------------------

    /// @notice Determines if adapter validation should run
    /// @dev Skips validation if no adapters are deployed (e.g., fresh deployment with noAdaptersInput)
    ///      Adapter wiring is handled separately from state migration in production
    /// @return true if adapters are deployed and wired, false otherwise
    function _shouldValidateAdapters() internal view returns (bool) {
        // If wormholeAdapter is not set, assume adapters aren't deployed yet
        if (config.contracts.wormholeAdapter == address(0)) return false;

        // Check if adapters are wired (quorum > 0 for any chain)
        MultiAdapter multiAdapterContract = MultiAdapter(config.contracts.multiAdapter);
        PoolId globalPool = PoolId.wrap(0);
        uint8 sampleQuorum = multiAdapterContract.quorum(IntegrationConstants.BASE_CENTRIFUGE_ID, globalPool);
        return sampleQuorum > 0;
    }

    /// @notice Determines if a chain should be validated based on network topology
    /// @param targetChainId The Centrifuge ID of the target chain
    /// @return true if the chain should be validated from the current chain
    function _shouldValidateChain(uint16 targetChainId) internal view returns (bool) {
        if (config.network.centrifugeId == targetChainId) {
            return false;
        }
        return true;
    }

    function _validateMultiAdapterConfiguration(
        MultiAdapter multiAdapterContract,
        uint16 centrifugeId,
        PoolId poolId,
        ChainConfigs.ChainConfig memory chainConfig
    ) internal view {
        _validateMultiAdapterParams(multiAdapterContract, centrifugeId, poolId, chainConfig);

        _validateAdapterOrder(multiAdapterContract, centrifugeId, poolId, chainConfig);
    }

    /// @notice Validates MultiAdapter quorum, threshold, and recoveryIndex parameters
    function _validateMultiAdapterParams(
        MultiAdapter multiAdapterContract,
        uint16 centrifugeId,
        PoolId poolId,
        ChainConfigs.ChainConfig memory chainConfig
    ) internal view {
        uint8 actualQuorum = multiAdapterContract.quorum(centrifugeId, poolId);
        uint8 actualThreshold = multiAdapterContract.threshold(centrifugeId, poolId);
        uint8 actualRecoveryIndex = multiAdapterContract.recoveryIndex(centrifugeId, poolId);

        // Calculate expected quorum
        uint8 expectedQuorum = _calculateExpectedQuorum(chainConfig);

        // Validate parameters
        assertEq(actualQuorum, expectedQuorum, _formatAdapterError("MultiAdapter", "quorum", chainConfig.name));
        assertTrue(
            actualThreshold <= actualQuorum, _formatAdapterError("MultiAdapter", "threshold > quorum", chainConfig.name)
        );
        assertTrue(
            actualRecoveryIndex <= actualQuorum,
            _formatAdapterError("MultiAdapter", "recoveryIndex > quorum", chainConfig.name)
        );
    }

    /// @notice Calculates expected quorum based on source and target chain capabilities
    function _calculateExpectedQuorum(ChainConfigs.ChainConfig memory chainConfig) internal view returns (uint8) {
        bool sourceSupportsAxelar = config.network.centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        bool sourceSupportsLayerZero = config.contracts.layerZeroAdapter != address(0);

        uint8 expectedQuorum = 1; // Wormhole (always)
        if (sourceSupportsAxelar && chainConfig.hasAxelar) expectedQuorum++;
        if (sourceSupportsLayerZero && chainConfig.hasLayerZero) expectedQuorum++;

        return expectedQuorum;
    }

    /// @notice Validates the order and presence of adapters in MultiAdapter
    function _validateAdapterOrder(
        MultiAdapter multiAdapterContract,
        uint16 centrifugeId,
        PoolId poolId,
        ChainConfigs.ChainConfig memory chainConfig
    ) internal view {
        // First adapter should always be Wormhole
        IAdapter primaryAdapter = multiAdapterContract.adapters(centrifugeId, poolId, 0);
        assertEq(
            address(primaryAdapter),
            config.contracts.wormholeAdapter,
            _formatAdapterError("MultiAdapter", "primary adapter", chainConfig.name)
        );

        uint8 adapterIndex = 1;
        bool sourceSupportsAxelar = config.network.centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        bool sourceSupportsLayerZero = config.contracts.layerZeroAdapter != address(0);

        if (sourceSupportsAxelar && chainConfig.hasAxelar) {
            IAdapter axelarAdapterInterface = multiAdapterContract.adapters(centrifugeId, poolId, adapterIndex);
            assertEq(
                address(axelarAdapterInterface),
                config.contracts.axelarAdapter,
                _formatAdapterError("MultiAdapter", "Axelar adapter", chainConfig.name)
            );
            adapterIndex++;
        }
        if (sourceSupportsLayerZero && chainConfig.hasLayerZero) {
            IAdapter lzAdapterInterface = multiAdapterContract.adapters(centrifugeId, poolId, adapterIndex);
            assertEq(
                address(lzAdapterInterface),
                config.contracts.layerZeroAdapter,
                _formatAdapterError("MultiAdapter", "LayerZero adapter", chainConfig.name)
            );
        }
    }

    /// @notice Helper function to validate Wormhole adapter source/destination mappings
    function _validateWormholeMapping(
        WormholeAdapter wormholeAdapterContract,
        uint16 wormholeId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source (inbound) mapping
        (uint16 sourceCentrifugeId, address sourceAddr) = wormholeAdapterContract.sources(wormholeId);
        assertEq(
            sourceCentrifugeId, centrifugeId, _formatAdapterError("WormholeAdapter", "source centrifugeId", chainName)
        );
        assertEq(
            sourceAddr,
            config.contracts.wormholeAdapter,
            _formatAdapterError("WormholeAdapter", "source address", chainName)
        );

        // Validate destination (outbound) mapping
        (uint16 destWormholeId, address destAddr) = wormholeAdapterContract.destinations(centrifugeId);
        assertEq(
            destWormholeId, wormholeId, _formatAdapterError("WormholeAdapter", "destination wormholeId", chainName)
        );
        assertEq(
            destAddr,
            config.contracts.wormholeAdapter,
            _formatAdapterError("WormholeAdapter", "destination address", chainName)
        );
    }

    /// @notice Helper function to validate Axelar adapter source/destination mappings
    function _validateAxelarMapping(
        AxelarAdapter axelarAdapterContract,
        string memory axelarId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source (inbound) mapping
        (uint16 sourceCentrifugeId, bytes32 sourceAddressHash) = axelarAdapterContract.sources(axelarId);
        assertEq(
            sourceCentrifugeId,
            centrifugeId,
            string(abi.encodePacked("AxelarAdapter source centrifugeId mismatch for ", chainName))
        );
        // Note: addressHash is keccak256 of the remote adapter address string
        bytes32 expectedAddressHash = keccak256(abi.encodePacked(vm.toString(config.contracts.axelarAdapter)));
        assertEq(
            sourceAddressHash,
            expectedAddressHash,
            _formatAdapterError("AxelarAdapter", "source addressHash", chainName)
        );

        // Validate destination (outbound) mapping
        (string memory destAxelarId, string memory destAddr) = axelarAdapterContract.destinations(centrifugeId);
        assertEq(
            keccak256(bytes(destAxelarId)),
            keccak256(bytes(axelarId)),
            _formatAdapterError("AxelarAdapter", "destination axelarId", chainName)
        );
        assertEq(
            keccak256(bytes(destAddr)),
            keccak256(abi.encodePacked(vm.toString(config.contracts.axelarAdapter))),
            _formatAdapterError("AxelarAdapter", "destination address", chainName)
        );
    }

    /// @notice Helper function to validate LayerZero adapter source/destination mappings
    function _validateLayerZeroMapping(
        LayerZeroAdapter layerZeroAdapterContract,
        uint32 layerZeroEid,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source (inbound) mapping
        (uint16 sourceCentrifugeId, address sourceAddr) = layerZeroAdapterContract.sources(layerZeroEid);
        assertEq(
            sourceCentrifugeId, centrifugeId, _formatAdapterError("LayerZeroAdapter", "source centrifugeId", chainName)
        );
        assertEq(
            sourceAddr,
            config.contracts.layerZeroAdapter,
            _formatAdapterError("LayerZeroAdapter", "source address", chainName)
        );

        // Validate destination (outbound) mapping
        (uint32 destLayerZeroEid, address destAddr) = layerZeroAdapterContract.destinations(centrifugeId);
        assertEq(
            destLayerZeroEid,
            layerZeroEid,
            _formatAdapterError("LayerZeroAdapter", "destination layerZeroEid", chainName)
        );
        assertEq(
            destAddr,
            config.contracts.layerZeroAdapter,
            _formatAdapterError("LayerZeroAdapter", "destination address", chainName)
        );
    }

    /// @notice Formats standardized adapter error messages
    /// @param adapterType The type of adapter (e.g., "WormholeAdapter", "AxelarAdapter", "LayerZeroAdapter")
    /// @param field The field that has a mismatch (e.g., "source centrifugeId", "destination address")
    function _formatAdapterError(string memory adapterType, string memory field, string memory chainName)
        private
        pure
        returns (string memory)
    {
        return string(abi.encodePacked(adapterType, " ", field, " mismatch for ", chainName));
    }

    //----------------------------------------------------------------------------------------------
    // SHARE TOKEN VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Generic function to validate any vault/share token configuration
    /// @param vaultAddress Optional vault address (can be address(0) to skip vault-specific validations)
    /// @param tokenName Optional human-readable token name solely for error messages
    function validateShareToken(
        IShareToken shareToken,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address vaultAddress,
        string memory tokenName
    ) public view virtual {
        _validateShareTokenWards(shareToken, config.contracts.balanceSheet, config.contracts.spoke, tokenName);

        _validateSpokeDeploymentChanges(poolId, shareClassId, shareToken, vaultAddress, tokenName);

        if (config.contracts.asyncRequestManager != address(0) && vaultAddress != address(0)) {
            _validateVaultRegistration(poolId, shareClassId, assetId, vaultAddress, tokenName);
        }

        _validateShareTokenVaultMapping(shareToken, assetId, tokenName);

        _validateDeployedV3Vault(shareToken, assetId, poolId, shareClassId, tokenName);

        if (config.contracts.asyncRequestManager != address(0)) {
            _validateBalanceSheetManager(
                poolId, config.contracts.asyncRequestManager, config.contracts.balanceSheet, tokenName
            );
        }
    }

    /// @notice Validates V3 share token ward permissions
    function _validateShareTokenWards(
        IShareToken shareToken,
        address balanceSheetAddress,
        address spokeAddress,
        string memory tokenName
    ) internal view virtual {
        assertEq(
            IAuth(address(shareToken)).wards(config.contracts.root),
            1,
            string(abi.encodePacked(tokenName, " share token should have ROOT as ward"))
        );
        assertEq(
            IAuth(address(shareToken)).wards(balanceSheetAddress),
            1,
            string(abi.encodePacked(tokenName, " share token should have BALANCE_SHEET as ward"))
        );
        assertEq(
            IAuth(address(shareToken)).wards(spokeAddress),
            1,
            string(abi.encodePacked(tokenName, " share token should have SPOKE as ward"))
        );
    }

    /// @notice Validates spoke storage changes from V3 token deployment
    function _validateSpokeDeploymentChanges(
        PoolId poolId,
        ShareClassId shareClassId,
        IShareToken shareToken,
        address vaultAddress,
        string memory tokenName
    ) internal view virtual {
        if (isV3_1()) {
            IShareToken linkedShareToken = ISpoke(config.contracts.spoke).shareToken(poolId, shareClassId);
            assertEq(
                address(linkedShareToken),
                address(shareToken),
                string(abi.encodePacked(tokenName, " share token should be linked to pool/share class in spoke"))
            );
        } else {
            address linkedShareToken = IV3_0_1_Spoke(config.contracts.spoke).shareToken(poolId, shareClassId);
            assertEq(
                linkedShareToken,
                address(shareToken),
                string(abi.encodePacked(tokenName, " share token should be linked to pool/share class in spoke"))
            );
        }

        if (isV3_1()) {
            assertTrue(
                ISpoke(config.contracts.spoke).isPoolActive(poolId),
                string(abi.encodePacked(tokenName, " pool should be active on spoke"))
            );
        } else {
            assertTrue(
                IV3_0_1_Spoke(config.contracts.spoke).isPoolActive(poolId),
                string(abi.encodePacked(tokenName, " pool should be active on spoke"))
            );
        }

        if (isV3_1()) {
            assertTrue(
                IVaultRegistry(config.contracts.vaultRegistry).isLinked(IVault(vaultAddress)),
                string(
                    abi.encodePacked("Deployed V3 ", tokenName, " vault should be marked as linked in VaultRegistry")
                )
            );
        } else {
            assertTrue(
                IV3_0_1_Spoke(config.contracts.spoke).isLinked(vaultAddress),
                string(abi.encodePacked("Deployed V3 ", tokenName, " vault should be marked as linked in spoke"))
            );
        }
    }

    /// @notice Validates vault registration in AsyncRequestManager (v3.0.1) or VaultRegistry (v3.1)
    function _validateVaultRegistration(
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address expectedVault,
        string memory tokenName
    ) internal view virtual {
        address actualVault;

        if (isV3_1()) {
            actualVault = address(
                IVaultRegistry(config.contracts.vaultRegistry)
                    .vault(poolId, shareClassId, assetId, IRequestManager(config.contracts.asyncRequestManager))
            );
        } else {
            actualVault =
                IV3_0_1_AsyncRequestManager(config.contracts.asyncRequestManager).vault(poolId, shareClassId, assetId);
        }

        assertEq(
            actualVault,
            expectedVault,
            string(
                abi.encodePacked(
                    isV3_1() ? "VaultRegistry" : "AsyncRequestManager",
                    " vault mapping should point to correct V3 ",
                    tokenName,
                    " vault"
                )
            )
        );
    }

    /// @notice Validates share token vault mapping points to deployed V3 vault
    function _validateShareTokenVaultMapping(IShareToken shareToken, AssetId assetId, string memory tokenName)
        internal
        view
        virtual
    {
        address assetAddress;

        if (isV3_1()) {
            (assetAddress,) = ISpoke(config.contracts.spoke).idToAsset(assetId);
        } else {
            (assetAddress,) = IV3_0_1_Spoke(config.contracts.spoke).idToAsset(assetId);
        }

        address vaultFromShareToken;

        if (isV3_1()) {
            vaultFromShareToken = IShareToken(address(shareToken)).vault(assetAddress);
        } else {
            vaultFromShareToken = IV3_0_1_ShareToken(address(shareToken)).vault(assetAddress);
        }

        assertTrue(
            vaultFromShareToken != address(0),
            string(abi.encodePacked(tokenName, " share token vault mapping should point to deployed V3 vault"))
        );

        assertTrue(
            vaultFromShareToken.code.length > 0,
            string(abi.encodePacked("V3 ", tokenName, " vault should have deployed code"))
        );
    }

    /// @notice Validates deployed V3 vault has correct configuration
    function _validateDeployedV3Vault(
        IShareToken shareToken,
        AssetId assetId,
        PoolId poolId,
        ShareClassId shareClassId,
        string memory tokenName
    ) internal view virtual {
        address assetAddress;

        if (isV3_1()) {
            (assetAddress,) = ISpoke(config.contracts.spoke).idToAsset(assetId);
        } else {
            (assetAddress,) = IV3_0_1_Spoke(config.contracts.spoke).idToAsset(assetId);
        }

        address v3VaultAddress;

        if (isV3_1()) {
            v3VaultAddress = IShareToken(address(shareToken)).vault(assetAddress);
        } else {
            v3VaultAddress = IV3_0_1_ShareToken(address(shareToken)).vault(assetAddress);
        }

        assertTrue(v3VaultAddress != address(0), string(abi.encodePacked("V3 ", tokenName, " vault should exist")));

        IBaseVault v3Vault = IBaseVault(v3VaultAddress);

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
    function _validateBalanceSheetManager(
        PoolId poolId,
        address requestManager,
        address balanceSheetAddress,
        string memory tokenName
    ) internal view virtual {
        IBalanceSheet balanceSheetContract = IBalanceSheet(balanceSheetAddress);

        assertTrue(
            balanceSheetContract.manager(poolId, requestManager),
            string(
                abi.encodePacked("RequestManager should be set as manager for ", tokenName, " pool in balance sheet")
            )
        );
    }

    //----------------------------------------------------------------------------------------------
    // VAULT VALIDATION (Chain-Specific)
    //----------------------------------------------------------------------------------------------

    /// @notice Validates vaults for the current chain based on centrifugeId
    /// @dev Only called for production environments (testnets are skipped at the caller level)
    function _validateVaults() internal view {
        if (config.network.centrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID) {
            _validateEthereumVaults();
        } else if (config.network.centrifugeId == IntegrationConstants.BASE_CENTRIFUGE_ID) {
            _validateBaseVaults();
        } else if (config.network.centrifugeId == IntegrationConstants.ARBITRUM_CENTRIFUGE_ID) {
            _validateArbitrumVaults();
        } else if (config.network.centrifugeId == IntegrationConstants.AVAX_CENTRIFUGE_ID) {
            _validateAvalancheVaults();
        } else if (config.network.centrifugeId == IntegrationConstants.BNB_CENTRIFUGE_ID) {
            _validateBNBVaults();
        } else if (config.network.centrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            _validatePlumeVaults();
        }
    }

    /// @notice Internal helper to validate Ethereum vaults
    function _validateEthereumVaults() internal view {
        AssetId usdcAssetId;
        AssetId jtrsyAssetId;
        AssetId jaaaAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_USDC, 0);
            jtrsyAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, 0);
            jaaaAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_USDC, 0);
            jtrsyAssetId =
                IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, 0);
            jaaaAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, 0);
        }

        if (ethJaaaVault != address(0) && ethJaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethJaaaShareToken),
                PoolId.wrap(IntegrationConstants.JAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JAAA_SC_ID)),
                usdcAssetId,
                ethJaaaVault,
                "ETH_JAAA"
            );
        }

        if (ethJtrsyVault != address(0) && ethJtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethJtrsyShareToken),
                PoolId.wrap(IntegrationConstants.JTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JTRSY_SC_ID)),
                usdcAssetId,
                ethJtrsyVault,
                "ETH_JTRSY"
            );
        }

        if (ethDejaaaVault != address(0) && ethDejaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDejaaaShareToken),
                PoolId.wrap(IntegrationConstants.DEJAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJAAA_SC_ID)),
                usdcAssetId,
                ethDejaaaVault,
                "ETH_DEJAAA_USDC"
            );
        }

        if (ethDejtrsyVault != address(0) && ethDejtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDejtrsyShareToken),
                PoolId.wrap(IntegrationConstants.DEJTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJTRSY_SC_ID)),
                usdcAssetId,
                ethDejtrsyVault,
                "ETH_DEJTRSY_USDC"
            );
        }

        if (ethDejtrsyJtrsyVaultA != address(0) && ethDejtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDejtrsyShareToken),
                PoolId.wrap(IntegrationConstants.DEJTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJTRSY_SC_ID)),
                jtrsyAssetId,
                ethDejtrsyJtrsyVaultA,
                "ETH_DEJTRSY_JTRSY_A"
            );
        }

        if (ethDejaaJaaaVaultA != address(0) && ethDejaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDejaaaShareToken),
                PoolId.wrap(IntegrationConstants.DEJAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJAAA_SC_ID)),
                jaaaAssetId,
                ethDejaaJaaaVaultA,
                "ETH_DEJAAA_JAAA_A"
            );
        }

        if (ethDejtrsyVault != address(0) && ethDejtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDejtrsyShareToken),
                PoolId.wrap(IntegrationConstants.DEJTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJTRSY_SC_ID)),
                usdcAssetId,
                ethDejtrsyVault,
                "ETH_DEJTRSY_VAULT"
            );
        }

        if (ethDistrictUsdcVault != address(0) && ethDistrictShareToken != address(0)) {
            validateShareToken(
                IShareToken(ethDistrictShareToken),
                PoolId.wrap(IntegrationConstants.DISTRICT_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DISTRICT_SC_ID)),
                usdcAssetId,
                ethDistrictUsdcVault,
                "ETH_DISTRICT_USDC"
            );
        }
    }

    /// @notice Internal helper to validate Base vaults
    function _validateBaseVaults() internal view {
        AssetId usdcAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.BASE_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.BASE_USDC, 0);
        }

        if (baseDejaaaUsdcVault != address(0) && baseDejaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(baseDejaaaShareToken),
                PoolId.wrap(IntegrationConstants.DEJAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJAAA_SC_ID)),
                usdcAssetId,
                baseDejaaaUsdcVault,
                "BASE_DEJAAA_USDC"
            );
        }

        if (baseJaaaUsdcVault != address(0) && baseJaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(baseJaaaShareToken),
                PoolId.wrap(IntegrationConstants.JAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JAAA_SC_ID)),
                usdcAssetId,
                baseJaaaUsdcVault,
                "BASE_JAAA_USDC"
            );
        }

        if (baseSpxaUsdcVault != address(0) && baseSpxaShareToken != address(0)) {
            validateShareToken(
                IShareToken(baseSpxaShareToken),
                PoolId.wrap(IntegrationConstants.SPXA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.SPXA_SC_ID)),
                usdcAssetId,
                baseSpxaUsdcVault,
                "BASE_SPXA_USDC"
            );
        }

        // NOTE: BASE_DEJAAA_JAAA vault (0x2D38c58Cc7d4DdD6B4DaF7b3539902a7667F4519) skipped due to missing share token (0x5a0F93D040De44e78F251b03c43be9CF317Dcf64) registration on Base Spoke
    }

    /// @notice Internal helper to validate Avalanche vaults
    function _validateAvalancheVaults() internal view {
        AssetId usdcAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.AVAX_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.AVAX_USDC, 0);
        }

        if (avaxJaaaVault != address(0) && avaxJaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(avaxJaaaShareToken),
                PoolId.wrap(IntegrationConstants.JAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JAAA_SC_ID)),
                usdcAssetId,
                avaxJaaaVault,
                "AVAX_JAAA_USDC"
            );
        }

        if (avaxDejtrsyUsdcVault != address(0) && avaxDejtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(avaxDejtrsyShareToken),
                PoolId.wrap(IntegrationConstants.DEJTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJTRSY_SC_ID)),
                usdcAssetId,
                avaxDejtrsyUsdcVault,
                "AVAX_DEJTRSY_USDC"
            );
        }

        if (avaxDejaaaUsdcVault != address(0) && avaxDejaaaShareToken != address(0)) {
            validateShareToken(
                IShareToken(avaxDejaaaShareToken),
                PoolId.wrap(IntegrationConstants.DEJAAA_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.DEJAAA_SC_ID)),
                usdcAssetId,
                avaxDejaaaUsdcVault,
                "AVAX_DEJAAA_USDC"
            );
        }

        if (avaxJtrsyUsdcVault != address(0) && avaxJtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(avaxJtrsyShareToken),
                PoolId.wrap(IntegrationConstants.JTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JTRSY_SC_ID)),
                usdcAssetId,
                avaxJtrsyUsdcVault,
                "AVAX_JTRSY_USDC"
            );
        }

        // NOTE: AVAX_DEJAAA_VAULT (0xCF4C60066aAB54b3f750F94c2a06046d5466Ccf9) skipped due to not being linked
        // NOTE: AVAX_DEJTRSY_JTRSY (0x04157759a9fe406d82a16BdEB20F9BeB9bBEb958) skipped due to missing share token (0xa5d465251fBCc907f5Dd6bB2145488DFC6a2627b) registration on AVAX Spoke
    }

    /// @notice Internal helper to validate Arbitrum vaults
    function _validateArbitrumVaults() internal view {
        // Skip vault validation if no vaults are set (fresh deployment)
        if (arbitrumJtrsyUsdcVault == address(0) && arbitrumDejaaaUsdcVault == address(0)) {
            return;
        }

        AssetId usdcAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.ARBITRUM_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.ARBITRUM_USDC, 0);
        }

        if (arbitrumJtrsyUsdcVault != address(0) && arbitrumJtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(arbitrumJtrsyShareToken),
                PoolId.wrap(IntegrationConstants.JTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JTRSY_SC_ID)),
                usdcAssetId,
                arbitrumJtrsyUsdcVault,
                "ARBITRUM_JTRSY_USDC"
            );
        }

        // NOTE: ARBITRUM_DEJAAA_USDC vault (0xe897E7F16e8F4ed568A62955b17744bCB3207d6E) skipped due to unset BalanceSheet.manager(IntegrationConstants.DEJAAA_POOL_ID, vault)
    }

    /// @notice Internal helper to validate BNB vaults
    function _validateBNBVaults() internal view {
        // Skip vault validation if no vaults are set (fresh deployment)
        if (bnbJtrsyUsdcVault == address(0) && bnbJaaaUsdcVault == address(0)) {
            return;
        }

        AssetId usdcAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.BNB_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.BNB_USDC, 0);
        }

        // NOTE: BNB_JTRSY_USDC vault (0x5aa84705a2CB2054ed303565336F188e6bfFbAF5) skipped due to unset BalanceSheet.manager(IntegrationConstants.JTRSY_POOL_ID, vault)
        // NOTE: BNB_JAAA_USDC vault (0x9effaa5614c689fA12892379e097b3ACaD239961) skipped due to unset BalanceSheet.manager(IntegrationConstants.JAAA_POOL_ID, vault)
    }

    /// @notice Internal helper to validate Plume vaults
    function _validatePlumeVaults() internal view {
        // Skip vault validation if no vaults are set (fresh deployment)
        if (
            plumeAcrdxUsdcVault == address(0) && plumeJtrsyUsdcVault == address(0)
                && plumeSyncDepositVault == address(0)
        ) {
            return;
        }

        AssetId usdcAssetId;
        AssetId pusdAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.PLUME_USDC, 0);
            pusdAssetId = ISpoke(config.contracts.spoke).assetToId(IntegrationConstants.PLUME_PUSD, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.PLUME_USDC, 0);
            pusdAssetId = IV3_0_1_Spoke(config.contracts.spoke).assetToId(IntegrationConstants.PLUME_PUSD, 0);
        }

        if (plumeAcrdxUsdcVault != address(0) && plumeAcrdxShareToken != address(0)) {
            validateShareToken(
                IShareToken(plumeAcrdxShareToken),
                PoolId.wrap(IntegrationConstants.ACRDX_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.ACRDX_SC_ID)),
                usdcAssetId,
                plumeAcrdxUsdcVault,
                "PLUME_ACRDX_USDC"
            );
        }

        if (plumeJtrsyUsdcVault != address(0) && plumeJtrsyShareToken != address(0)) {
            validateShareToken(
                IShareToken(plumeJtrsyShareToken),
                PoolId.wrap(IntegrationConstants.JTRSY_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.JTRSY_SC_ID)),
                usdcAssetId,
                plumeJtrsyUsdcVault,
                "PLUME_JTRSY_USDC"
            );
        }

        if (plumeSyncDepositVault != address(0) && plumeTestShareToken != address(0)) {
            validateShareToken(
                IShareToken(plumeTestShareToken),
                PoolId.wrap(IntegrationConstants.PLUME_TEST_POOL_ID),
                ShareClassId.wrap(bytes16(IntegrationConstants.PLUME_TEST_SC_ID)),
                pusdAssetId,
                plumeSyncDepositVault,
                "PLUME_TEST_PUSD"
            );
        }
    }
}
