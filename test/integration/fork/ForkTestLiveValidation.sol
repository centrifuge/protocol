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
import {Holdings} from "../../../src/core/hub/Holdings.sol";
import {Accounting} from "../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../../src/core/hub/HubRegistry.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/core/spoke/interfaces/IVault.sol";
import {BalanceSheet} from "../../../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../../../src/core/messaging/GasService.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultRegistry} from "../../../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../../../src/core/utils/ContractUpdater.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {ShareClassManager} from "../../../src/core/hub/ShareClassManager.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {TokenFactory} from "../../../src/core/spoke/factories/TokenFactory.sol";
import {IRequestManager} from "../../../src/core/interfaces/IRequestManager.sol";
import {MessageProcessor} from "../../../src/core/messaging/MessageProcessor.sol";
import {IBalanceSheet} from "../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";
import {IVaultRegistry} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";
import {PoolEscrowFactory} from "../../../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../../../src/admin/Root.sol";
import {OpsGuardian} from "../../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../../src/admin/ProtocolGuardian.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../../src/vaults/BatchRequestManager.sol";

import {FullReport} from "../../../script/FullDeployer.s.sol";

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
    // CORE SYSTEM CONTRACTS
    //----------------------------------------------------------------------------------------------

    address public root;
    address public protocolGuardian;
    address public opsGuardian;
    address public gateway;
    address public gasService;
    address public tokenRecoverer;
    address public messageProcessor;
    address public messageDispatcher;
    address public multiAdapter;

    // Hub contracts
    address public hubRegistry;
    address public accounting;
    address public holdings;
    address public shareClassManager;
    address public hub;
    address public hubHandler;
    address public batchRequestManager;
    address public identityValuation;

    // Spoke contracts
    address public tokenFactory;
    address public balanceSheet;
    address public spoke;
    address public vaultRegistry;
    address public contractUpdater;
    address public poolEscrowFactory;

    // Vault system
    address public router;
    address public asyncRequestManager;
    address public syncManager;
    address public refundEscrowFactory;
    address public subsidyManager;

    // Adapters
    address public wormholeAdapter;
    address public axelarAdapter;
    address public layerZeroAdapter;

    // Admin
    address public adminSafe;

    //----------------------------------------------------------------------------------------------
    // FACTORY CONTRACTS
    //----------------------------------------------------------------------------------------------

    address public asyncVaultFactory;
    address public syncDepositVaultFactory;

    //----------------------------------------------------------------------------------------------
    // HOOK CONTRACTS
    //----------------------------------------------------------------------------------------------

    address public freezeOnlyHook;
    address public fullRestrictionsHook;
    address public freelyTransferableHook;
    address public redemptionRestrictionsHook;

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
    // MULTICHAIN CONFIG
    //----------------------------------------------------------------------------------------------

    uint16 internal localCentrifugeId;

    //----------------------------------------------------------------------------------------------
    // SETUP
    //----------------------------------------------------------------------------------------------

    function setUp() public virtual override {
        super.setUp();
        _initializeContractAddresses();
        _setupVMLabels();
    }

    /// @notice Configure chain-specific settings
    /// @param adminSafe_ The admin safe address for this chain
    /// @param centrifugeId_ The centrifuge chain ID
    function _configureChain(address adminSafe_, uint16 centrifugeId_) public {
        localCentrifugeId = centrifugeId_;
        adminSafe = adminSafe_;
    }

    /// @notice Detects if the deployment is v3.1 or v3.0.1
    function isV3_1() internal view returns (bool) {
        return vaultRegistry != address(0) && vaultRegistry.code.length > 0;
    }

    /// @notice Helper function to determine if current chain is Ethereum
    function isEthereum() internal view returns (bool) {
        return localCentrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID;
    }

    /// @notice Initialize all contract addresses from IntegrationConstants
    function _initializeContractAddresses() public virtual {
        // Core system contracts
        root = IntegrationConstants.ROOT;
        protocolGuardian = IntegrationConstants.PROTOCOL_GUARDIAN;
        opsGuardian = IntegrationConstants.OPS_GUARDIAN;
        gateway = IntegrationConstants.GATEWAY;
        gasService = IntegrationConstants.GAS_SERVICE;
        tokenRecoverer = IntegrationConstants.TOKEN_RECOVERER;
        messageProcessor = IntegrationConstants.MESSAGE_PROCESSOR;
        messageDispatcher = IntegrationConstants.MESSAGE_DISPATCHER;
        multiAdapter = IntegrationConstants.MULTI_ADAPTER;

        // Hub contracts
        hubRegistry = IntegrationConstants.HUB_REGISTRY;
        accounting = IntegrationConstants.ACCOUNTING;
        holdings = IntegrationConstants.HOLDINGS;
        shareClassManager = IntegrationConstants.SHARE_CLASS_MANAGER;
        hub = IntegrationConstants.HUB;
        hubHandler = IntegrationConstants.HUB_HANDLER;
        batchRequestManager = IntegrationConstants.BATCH_REQUEST_MANAGER;
        identityValuation = IntegrationConstants.IDENTITY_VALUATION;

        // Spoke contracts
        tokenFactory = IntegrationConstants.TOKEN_FACTORY;
        balanceSheet = IntegrationConstants.BALANCE_SHEET;
        spoke = IntegrationConstants.SPOKE;
        vaultRegistry = IntegrationConstants.VAULT_REGISTRY;
        contractUpdater = IntegrationConstants.CONTRACT_UPDATER;
        poolEscrowFactory = IntegrationConstants.POOL_ESCROW_FACTORY;

        // Vault system
        router = IntegrationConstants.ROUTER;
        asyncRequestManager = IntegrationConstants.ASYNC_REQUEST_MANAGER;
        syncManager = IntegrationConstants.SYNC_MANAGER;
        refundEscrowFactory = IntegrationConstants.REFUND_ESCROW_FACTORY;

        // Adapters
        wormholeAdapter = IntegrationConstants.WORMHOLE_ADAPTER;
        axelarAdapter = IntegrationConstants.AXELAR_ADAPTER;
        layerZeroAdapter = IntegrationConstants.LAYER_ZERO_ADAPTER;

        // Factory contracts
        asyncVaultFactory = IntegrationConstants.ASYNC_VAULT_FACTORY;
        syncDepositVaultFactory = IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY;

        // Hook contracts
        freezeOnlyHook = IntegrationConstants.FREEZE_ONLY_HOOK;
        fullRestrictionsHook = IntegrationConstants.FULL_RESTRICTIONS_HOOK;
        freelyTransferableHook = IntegrationConstants.FREELY_TRANSFERABLE_HOOK;
        redemptionRestrictionsHook = IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK;

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

        // Multichain config
        localCentrifugeId = IntegrationConstants.ETH_CENTRIFUGE_ID;
        adminSafe = IntegrationConstants.ETH_ADMIN_SAFE; // Default for standalone tests
    }

    /// @notice Load contract addresses from a FullDeployer instance (for pre-migration testing)
    /// @dev Alternative to _initializeContractAddresses() when testing fresh deployments
    ///      Use this when validating a freshly deployed v3.1 system in fork (e.g., MigrationV3_1Test)
    ///      Use _initializeContractAddresses() when validating live on-chain state (post-migration)
    /// @param report The FullReport instance that comes from the deployed v3.1 contracts
    function loadContractsFromDeployer(FullReport memory report, address adminSafe_) public virtual {
        // Core system contracts
        root = address(report.root);
        protocolGuardian = address(report.protocolGuardian);
        opsGuardian = address(report.opsGuardian);
        gateway = address(report.core.gateway);
        gasService = address(report.core.gasService);
        tokenRecoverer = address(report.tokenRecoverer);
        messageProcessor = address(report.core.messageProcessor);
        messageDispatcher = address(report.core.messageDispatcher);
        multiAdapter = address(report.core.multiAdapter);

        // Hub contracts
        hubRegistry = address(report.core.hubRegistry);
        accounting = address(report.core.accounting);
        holdings = address(report.core.holdings);
        shareClassManager = address(report.core.shareClassManager);
        hub = address(report.core.hub);
        hubHandler = address(report.core.hubHandler);
        batchRequestManager = address(report.batchRequestManager);
        identityValuation = address(report.identityValuation);

        // Spoke contracts
        tokenFactory = address(report.core.tokenFactory);
        balanceSheet = address(report.core.balanceSheet);
        spoke = address(report.core.spoke);
        vaultRegistry = address(report.core.vaultRegistry);
        contractUpdater = address(report.core.contractUpdater);
        poolEscrowFactory = address(report.core.poolEscrowFactory);

        // Vault system
        router = address(report.vaultRouter);
        asyncRequestManager = address(report.asyncRequestManager);
        syncManager = address(report.syncManager);
        refundEscrowFactory = address(report.refundEscrowFactory);
        subsidyManager = address(report.subsidyManager);

        // Skip wormholeAdapter, axelarAdapter, layerZeroAdapter due to not being public in FullDeployer
        // Can be queried via multiAdapter.adapters()

        // Factory contracts
        asyncVaultFactory = address(report.asyncVaultFactory);
        syncDepositVaultFactory = address(report.syncDepositVaultFactory);

        // Hook contracts
        freezeOnlyHook = address(report.freezeOnlyHook);
        fullRestrictionsHook = address(report.fullRestrictionsHook);
        freelyTransferableHook = address(report.freelyTransferableHook);
        redemptionRestrictionsHook = address(report.redemptionRestrictionsHook);

        // Multichain config - from deployed contracts
        localCentrifugeId = report.core.messageDispatcher.localCentrifugeId();
        adminSafe = adminSafe_;
    }

    /// @notice Setup VM labels for debugging
    function _setupVMLabels() internal virtual override {
        // Call parent VMLabeling to label all IntegrationConstants
        super._setupVMLabels();

        // Additional labels for instance variables (if they differ from constants)
        vm.label(root, "Root");
        vm.label(protocolGuardian, "ProtocolGuardian");
        vm.label(gateway, "Gateway");
        vm.label(gasService, "GasService");
        vm.label(tokenRecoverer, "TokenRecoverer");
        vm.label(messageProcessor, "MessageProcessor");
        vm.label(messageDispatcher, "MessageDispatcher");
        vm.label(multiAdapter, "MultiAdapter");
        vm.label(hubRegistry, "HubRegistry");
        vm.label(accounting, "Accounting");
        vm.label(holdings, "Holdings");
        vm.label(shareClassManager, "ShareClassManager");
        vm.label(hub, "Hub");
        vm.label(identityValuation, "IdentityValuation");
        vm.label(tokenFactory, "TokenFactory");
        vm.label(balanceSheet, "BalanceSheet");
        vm.label(spoke, "Spoke");
        vm.label(contractUpdater, "ContractUpdater");
        vm.label(poolEscrowFactory, "PoolEscrowFactory");
        vm.label(router, "VaultRouter");
        vm.label(asyncRequestManager, "AsyncRequestManager");
        vm.label(syncManager, "SyncManager");
        vm.label(wormholeAdapter, "WormholeAdapter");
        vm.label(axelarAdapter, "AxelarAdapter");
        vm.label(asyncVaultFactory, "AsyncVaultFactory");
        vm.label(syncDepositVaultFactory, "SyncDepositVaultFactory");
        vm.label(freezeOnlyHook, "FreezeOnlyHook");
        vm.label(fullRestrictionsHook, "FullRestrictionsHook");
        vm.label(freelyTransferableHook, "FreelyTransferableHook");
        vm.label(redemptionRestrictionsHook, "RedemptionRestrictionsHook");
    }

    //----------------------------------------------------------------------------------------------
    // VALIDATION ENTRY POINTS
    //----------------------------------------------------------------------------------------------

    function test_validateCompleteDeployment() public virtual {
        vm.skip(true); // Skip until v3.1 is deployed - v3.0.1 has different ward relationships
        if (localCentrifugeId == 0) {
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
        _validateRootWard(gateway);
        _validateRootWard(multiAdapter);
        _validateRootWard(messageDispatcher);
        _validateRootWard(messageProcessor);

        // From CoreDeployer - Spoke contracts
        _validateRootWard(poolEscrowFactory);
        _validateRootWard(tokenFactory);
        _validateRootWard(spoke);
        _validateRootWard(balanceSheet);
        _validateRootWard(contractUpdater);
        if (vaultRegistry != address(0)) _validateRootWard(vaultRegistry); // TODO: Remove condition when constant added

        // From CoreDeployer - Hub contracts
        _validateRootWard(hubRegistry);
        _validateRootWard(accounting);
        _validateRootWard(holdings);
        _validateRootWard(shareClassManager);
        _validateRootWard(hub);
        if (hubHandler != address(0)) _validateRootWard(hubHandler); // TODO: Remove condition when constant added

        // From FullDeployer - Admin & escrows
        _validateRootWard(tokenRecoverer);
        if (refundEscrowFactory != address(0)) _validateRootWard(refundEscrowFactory); // TODO: Remove condition when constant added

        // From FullDeployer - Vault system
        _validateRootWard(asyncVaultFactory);
        _validateRootWard(asyncRequestManager);
        _validateRootWard(syncDepositVaultFactory);
        _validateRootWard(syncManager);
        _validateRootWard(router);

        // From FullDeployer - Hooks
        _validateRootWard(freezeOnlyHook);
        _validateRootWard(fullRestrictionsHook);
        _validateRootWard(freelyTransferableHook);
        _validateRootWard(redemptionRestrictionsHook);

        // From FullDeployer - Batch request manager
        if (batchRequestManager != address(0)) _validateRootWard(batchRequestManager); // TODO: Remove condition when constant added

        // From FullDeployer - Adapters
        if (wormholeAdapter != address(0)) _validateRootWard(wormholeAdapter);
        if (axelarAdapter != address(0)) _validateRootWard(axelarAdapter);
        if (layerZeroAdapter != address(0)) _validateRootWard(layerZeroAdapter);

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
        } else if (localCentrifugeId == IntegrationConstants.BASE_CENTRIFUGE_ID) {
            if (baseJaaaUsdcVault != address(0)) _validateRootWard(baseJaaaUsdcVault);
            if (baseDejaaaUsdcVault != address(0)) _validateRootWard(baseDejaaaUsdcVault);
            if (baseDejaaaJaaaVault != address(0)) _validateRootWard(baseDejaaaJaaaVault);
            if (baseSpxaUsdcVault != address(0)) _validateRootWard(baseSpxaUsdcVault);

            if (baseJaaaShareToken != address(0)) _validateRootWard(baseJaaaShareToken);
            if (baseJtrsyShareToken != address(0)) _validateRootWard(baseJtrsyShareToken);
            if (baseDejaaaShareToken != address(0)) _validateRootWard(baseDejaaaShareToken);
            if (baseDejtrsyShareToken != address(0)) _validateRootWard(baseDejtrsyShareToken);
            if (baseSpxaShareToken != address(0)) _validateRootWard(baseSpxaShareToken);
        } else if (localCentrifugeId == IntegrationConstants.ARBITRUM_CENTRIFUGE_ID) {
            if (arbitrumJtrsyShareToken != address(0)) _validateRootWard(arbitrumJtrsyShareToken);
            if (arbitrumDejaaaShareToken != address(0)) _validateRootWard(arbitrumDejaaaShareToken);
            if (arbitrumDejtrsyShareToken != address(0)) _validateRootWard(arbitrumDejtrsyShareToken);
        } else if (localCentrifugeId == IntegrationConstants.AVAX_CENTRIFUGE_ID) {
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
        } else if (localCentrifugeId == IntegrationConstants.BNB_CENTRIFUGE_ID) {
            if (bnbJaaaShareToken != address(0)) _validateRootWard(bnbJaaaShareToken);
            if (bnbJtrsyShareToken != address(0)) _validateRootWard(bnbJtrsyShareToken);
        } else if (localCentrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
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
            IAuth(contractAddr).wards(root),
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
            _validateWard(root, messageProcessor);
            _validateWard(root, messageDispatcher);
        }

        _validateWard(multiAdapter, gateway);
        _validateWard(gateway, multiAdapter);
        _validateWard(gateway, messageDispatcher);
        // NOTE: gateway.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(gateway, messageProcessor);
        }
        _validateWard(gateway, spoke);

        _validateWard(messageProcessor, gateway);
        // NOTE: multiAdapter.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(multiAdapter, messageProcessor);
        }
        _validateWard(multiAdapter, hub);

        _validateWard(spoke, messageDispatcher);
        _validateWard(balanceSheet, messageDispatcher);
        _validateWard(contractUpdater, messageDispatcher);
        if (vaultRegistry != address(0)) _validateWard(vaultRegistry, messageDispatcher);
        if (hubHandler != address(0)) _validateWard(hubHandler, messageDispatcher);
        _validateWard(messageDispatcher, spoke);
        _validateWard(messageDispatcher, balanceSheet);
        _validateWard(messageDispatcher, hub);
        if (hubHandler != address(0)) _validateWard(messageDispatcher, hubHandler);

        // NOTE: gateway.rely(messageProcessor) is set in v3.1 CoreDeployer, not in v3.0.1
        if (!skipNewRootChecks) {
            _validateWard(gateway, messageProcessor);
        }
        _validateWard(spoke, messageProcessor);
        _validateWard(balanceSheet, messageProcessor);
        _validateWard(contractUpdater, messageProcessor);
        if (vaultRegistry != address(0)) _validateWard(vaultRegistry, messageProcessor);
        if (hubHandler != address(0)) _validateWard(hubHandler, messageProcessor);

        // ==================== SPOKE SIDE (CoreDeployer) ====================

        _validateWard(messageDispatcher, spoke);
        _validateWard(tokenFactory, spoke);
        _validateWard(poolEscrowFactory, spoke);
        if (vaultRegistry != address(0)) _validateWard(spoke, vaultRegistry);

        _validateWard(messageDispatcher, balanceSheet);

        // ==================== HUB SIDE (CoreDeployer) ====================

        _validateWard(accounting, hub);
        _validateWard(holdings, hub);
        _validateWard(hubRegistry, hub);
        _validateWard(shareClassManager, hub);
        _validateWard(messageDispatcher, hub);
        if (hubHandler != address(0)) _validateWard(hub, hubHandler);

        if (hubHandler != address(0)) {
            _validateWard(hubRegistry, hubHandler);
            _validateWard(holdings, hubHandler);
            _validateWard(shareClassManager, hubHandler);
            _validateWard(messageDispatcher, hubHandler);
        }

        // ==================== VAULT SIDE (FullDeployer) ====================

        _validateWard(asyncRequestManager, spoke);
        _validateWard(asyncRequestManager, contractUpdater);
        _validateWard(asyncRequestManager, asyncVaultFactory);
        _validateWard(asyncRequestManager, syncDepositVaultFactory);

        _validateWard(syncManager, contractUpdater);
        _validateWard(syncManager, syncDepositVaultFactory);

        if (vaultRegistry != address(0)) {
            _validateWard(asyncVaultFactory, vaultRegistry);
            _validateWard(syncDepositVaultFactory, vaultRegistry);
        }

        // ==================== HOOK (FullDeployer) ====================

        _validateWard(freezeOnlyHook, spoke);
        _validateWard(fullRestrictionsHook, spoke);
        _validateWard(freelyTransferableHook, spoke);
        _validateWard(redemptionRestrictionsHook, spoke);

        // ==================== BATCH REQUEST MANAGER (FullDeployer) ====================

        if (batchRequestManager != address(0)) {
            _validateWard(batchRequestManager, hub);
            if (hubHandler != address(0)) _validateWard(batchRequestManager, hubHandler);
        }

        // ==================== GUARDIAN (FullDeployer) ====================

        if (protocolGuardian != address(0)) {
            _validateWard(gateway, protocolGuardian);
            _validateWard(multiAdapter, protocolGuardian);
            _validateWard(messageDispatcher, protocolGuardian);
            if (!skipNewRootChecks) {
                _validateWard(root, protocolGuardian);
            }
            _validateWard(tokenRecoverer, protocolGuardian);
            if (wormholeAdapter != address(0)) _validateWard(wormholeAdapter, protocolGuardian);
            if (axelarAdapter != address(0)) _validateWard(axelarAdapter, protocolGuardian);
            if (layerZeroAdapter != address(0)) _validateWard(layerZeroAdapter, protocolGuardian);
        }

        if (opsGuardian != address(0)) {
            _validateWard(multiAdapter, opsGuardian);
            _validateWard(hub, opsGuardian);

            // Temporal wards for initial adapter wiring
            if (wormholeAdapter != address(0)) _validateWard(wormholeAdapter, opsGuardian);
            if (axelarAdapter != address(0)) _validateWard(axelarAdapter, opsGuardian);
            if (layerZeroAdapter != address(0)) _validateWard(layerZeroAdapter, opsGuardian);
        }

        if (layerZeroAdapter != address(0) && adminSafe != address(0)) {
            _validateWard(layerZeroAdapter, adminSafe);
        }

        // ==================== TOKEN RECOVERER (FullDeployer) ====================

        if (!skipNewRootChecks) {
            _validateWard(root, tokenRecoverer);
        }
        _validateWard(tokenRecoverer, messageDispatcher);
        _validateWard(tokenRecoverer, messageProcessor);
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

        assertEq(address(Gateway(payable(gateway)).adapter()), multiAdapter, "Gateway adapter mismatch");
        assertEq(
            address(Gateway(payable(gateway)).messageProperties()), gasService, "Gateway messageProperties mismatch"
        );
        assertEq(address(Gateway(payable(gateway)).processor()), messageProcessor, "Gateway processor mismatch");

        assertEq(
            address(MultiAdapter(multiAdapter).messageProperties()),
            gasService,
            "MultiAdapter messageProperties mismatch"
        );

        assertEq(address(MessageDispatcher(messageDispatcher).spoke()), spoke, "MessageDispatcher spoke mismatch");
        assertEq(
            address(MessageDispatcher(messageDispatcher).balanceSheet()),
            balanceSheet,
            "MessageDispatcher balanceSheet mismatch"
        );
        assertEq(
            address(MessageDispatcher(messageDispatcher).contractUpdater()),
            contractUpdater,
            "MessageDispatcher contractUpdater mismatch"
        );
        assertEq(
            address(MessageDispatcher(messageDispatcher).tokenRecoverer()),
            tokenRecoverer,
            "MessageDispatcher tokenRecoverer mismatch"
        );
        if (vaultRegistry != address(0)) {
            assertEq(
                address(MessageDispatcher(messageDispatcher).vaultRegistry()),
                vaultRegistry,
                "MessageDispatcher vaultRegistry mismatch"
            );
        }
        if (hubHandler != address(0)) {
            assertEq(
                address(MessageDispatcher(messageDispatcher).hubHandler()),
                hubHandler,
                "MessageDispatcher hubHandler mismatch"
            );
        }

        assertEq(
            address(MessageProcessor(messageProcessor).multiAdapter()),
            multiAdapter,
            "MessageProcessor multiAdapter mismatch"
        );
        assertEq(address(MessageProcessor(messageProcessor).gateway()), gateway, "MessageProcessor gateway mismatch");
        assertEq(address(MessageProcessor(messageProcessor).spoke()), spoke, "MessageProcessor spoke mismatch");
        assertEq(
            address(MessageProcessor(messageProcessor).balanceSheet()),
            balanceSheet,
            "MessageProcessor balanceSheet mismatch"
        );
        assertEq(
            address(MessageProcessor(messageProcessor).contractUpdater()),
            contractUpdater,
            "MessageProcessor contractUpdater mismatch"
        );
        assertEq(
            address(MessageProcessor(messageProcessor).tokenRecoverer()),
            tokenRecoverer,
            "MessageProcessor tokenRecoverer mismatch"
        );
        if (vaultRegistry != address(0)) {
            assertEq(
                address(MessageProcessor(messageProcessor).vaultRegistry()),
                vaultRegistry,
                "MessageProcessor vaultRegistry mismatch"
            );
        }
        if (hubHandler != address(0)) {
            assertEq(
                address(MessageProcessor(messageProcessor).hubHandler()),
                hubHandler,
                "MessageProcessor hubHandler mismatch"
            );
        }

        // ==================== SPOKE SIDE (CoreDeployer) ====================

        assertEq(address(Spoke(spoke).gateway()), gateway, "Spoke gateway mismatch");
        assertEq(address(Spoke(spoke).poolEscrowFactory()), poolEscrowFactory, "Spoke poolEscrowFactory mismatch");
        // NOTE: spoke.sender is set by MigrationSpell, not CoreDeployer (when reusing existing Root)
        if (!preMigration) {
            assertEq(address(Spoke(spoke).sender()), messageDispatcher, "Spoke sender mismatch");
        }

        assertEq(address(BalanceSheet(balanceSheet).spoke()), spoke, "BalanceSheet spoke mismatch");
        assertEq(address(BalanceSheet(balanceSheet).gateway()), gateway, "BalanceSheet gateway mismatch");
        assertEq(
            address(BalanceSheet(balanceSheet).poolEscrowProvider()),
            poolEscrowFactory,
            "BalanceSheet poolEscrowProvider mismatch"
        );
        assertEq(address(BalanceSheet(balanceSheet).sender()), messageDispatcher, "BalanceSheet sender mismatch");

        if (vaultRegistry != address(0)) {
            assertEq(address(VaultRegistry(vaultRegistry).spoke()), spoke, "VaultRegistry spoke mismatch");
        }

        // ==================== HUB SIDE (CoreDeployer) ====================

        assertEq(address(Hub(hub).sender()), messageDispatcher, "Hub sender mismatch");

        if (hubHandler != address(0)) {
            assertEq(address(HubHandler(hubHandler).sender()), messageDispatcher, "HubHandler sender mismatch");
        }

        // ==================== VAULT SIDE (FullDeployer) ====================

        if (refundEscrowFactory != address(0) && subsidyManager != address(0)) {
            assertEq(
                address(RefundEscrowFactory(refundEscrowFactory).controller()),
                subsidyManager,
                "RefundEscrowFactory controller mismatch"
            );
        }

        assertEq(
            address(AsyncRequestManager(payable(asyncRequestManager)).spoke()),
            spoke,
            "AsyncRequestManager spoke mismatch"
        );
        assertEq(
            address(AsyncRequestManager(payable(asyncRequestManager)).balanceSheet()),
            balanceSheet,
            "AsyncRequestManager balanceSheet mismatch"
        );
        if (vaultRegistry != address(0)) {
            assertEq(
                address(AsyncRequestManager(payable(asyncRequestManager)).vaultRegistry()),
                vaultRegistry,
                "AsyncRequestManager vaultRegistry mismatch"
            );
        }

        assertEq(address(SyncManager(syncManager).spoke()), spoke, "SyncManager spoke mismatch");
        assertEq(address(SyncManager(syncManager).balanceSheet()), balanceSheet, "SyncManager balanceSheet mismatch");
        if (vaultRegistry != address(0)) {
            assertEq(
                address(SyncManager(syncManager).vaultRegistry()), vaultRegistry, "SyncManager vaultRegistry mismatch"
            );
        }

        if (batchRequestManager != address(0)) {
            assertEq(address(BatchRequestManager(batchRequestManager).hub()), hub, "BatchRequestManager hub mismatch");
        }

        // ==================== GUARDIAN  ====================

        if (opsGuardian != address(0)) {
            address opsSafeAddr = address(OpsGuardian(opsGuardian).opsSafe());
            assertTrue(opsSafeAddr != address(0), "OpsGuardian opsSafe not configured");
        }

        if (protocolGuardian != address(0) && adminSafe != address(0)) {
            assertEq(address(ProtocolGuardian(protocolGuardian).safe()), adminSafe, "ProtocolGuardian safe mismatch");
        }
    }

    //----------------------------------------------------------------------------------------------
    // ENDORSEMENTS VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates Root endorsements
    function _validateEndorsements() internal view {
        assertTrue(Root(root).endorsed(balanceSheet), "BalanceSheet not endorsed by Root");
        assertTrue(Root(root).endorsed(asyncRequestManager), "AsyncRequestManager not endorsed by Root");
        assertTrue(Root(root).endorsed(router), "VaultRouter not endorsed by Root");
    }

    //----------------------------------------------------------------------------------------------
    // ADAPTER VALIDATION
    //----------------------------------------------------------------------------------------------

    /// @notice Validates MultiAdapter configurations for all connected chains (GLOBAL_POOL only)
    function _validateGuardianAdapterConfigurations() internal view virtual {
        MultiAdapter multiAdapterContract = MultiAdapter(multiAdapter);
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
                if (wormholeAdapter != address(0)) {
                    _validateWormholeMapping(
                        WormholeAdapter(wormholeAdapter), chains[i].wormholeId, chains[i].centrifugeId, chains[i].name
                    );
                }

                // Validate Axelar mapping if both current chain and target chain support it
                if (
                    axelarAdapter != address(0) && localCentrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID
                        && chains[i].hasAxelar
                ) {
                    _validateAxelarMapping(
                        AxelarAdapter(axelarAdapter), chains[i].axelarId, chains[i].centrifugeId, chains[i].name
                    );
                }

                // Validate LayerZero mapping if both current chain and target chain support it
                if (
                    layerZeroAdapter != address(0) && localCentrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID
                        && chains[i].hasLayerZero
                ) {
                    _validateLayerZeroMapping(
                        LayerZeroAdapter(layerZeroAdapter),
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
        if (wormholeAdapter == address(0)) return false;

        // Check if adapters are wired (quorum > 0 for any chain)
        MultiAdapter multiAdapterContract = MultiAdapter(multiAdapter);
        PoolId globalPool = PoolId.wrap(0);
        uint8 sampleQuorum = multiAdapterContract.quorum(IntegrationConstants.BASE_CENTRIFUGE_ID, globalPool);
        return sampleQuorum > 0;
    }

    /// @notice Determines if a chain should be validated based on network topology
    /// @param targetChainId The Centrifuge ID of the target chain
    /// @return true if the chain should be validated from the current chain
    function _shouldValidateChain(uint16 targetChainId) internal view returns (bool) {
        if (localCentrifugeId == targetChainId) {
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
        bool sourceSupportsAxelar = localCentrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        bool sourceSupportsLayerZero = layerZeroAdapter != address(0);

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
            wormholeAdapter,
            _formatAdapterError("MultiAdapter", "primary adapter", chainConfig.name)
        );

        uint8 adapterIndex = 1;
        bool sourceSupportsAxelar = localCentrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        bool sourceSupportsLayerZero = layerZeroAdapter != address(0);

        if (sourceSupportsAxelar && chainConfig.hasAxelar) {
            IAdapter axelarAdapterInterface = multiAdapterContract.adapters(centrifugeId, poolId, adapterIndex);
            assertEq(
                address(axelarAdapterInterface),
                axelarAdapter,
                _formatAdapterError("MultiAdapter", "Axelar adapter", chainConfig.name)
            );
            adapterIndex++;
        }
        if (sourceSupportsLayerZero && chainConfig.hasLayerZero) {
            IAdapter lzAdapterInterface = multiAdapterContract.adapters(centrifugeId, poolId, adapterIndex);
            assertEq(
                address(lzAdapterInterface),
                layerZeroAdapter,
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
        assertEq(sourceAddr, wormholeAdapter, _formatAdapterError("WormholeAdapter", "source address", chainName));

        // Validate destination (outbound) mapping
        (uint16 destWormholeId, address destAddr) = wormholeAdapterContract.destinations(centrifugeId);
        assertEq(
            destWormholeId, wormholeId, _formatAdapterError("WormholeAdapter", "destination wormholeId", chainName)
        );
        assertEq(destAddr, wormholeAdapter, _formatAdapterError("WormholeAdapter", "destination address", chainName));
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
        bytes32 expectedAddressHash = keccak256(abi.encodePacked(vm.toString(axelarAdapter)));
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
            keccak256(abi.encodePacked(vm.toString(axelarAdapter))),
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
        assertEq(sourceAddr, layerZeroAdapter, _formatAdapterError("LayerZeroAdapter", "source address", chainName));

        // Validate destination (outbound) mapping
        (uint32 destLayerZeroEid, address destAddr) = layerZeroAdapterContract.destinations(centrifugeId);
        assertEq(
            destLayerZeroEid,
            layerZeroEid,
            _formatAdapterError("LayerZeroAdapter", "destination layerZeroEid", chainName)
        );
        assertEq(destAddr, layerZeroAdapter, _formatAdapterError("LayerZeroAdapter", "destination address", chainName));
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
        _validateShareTokenWards(shareToken, balanceSheet, spoke, tokenName);

        _validateSpokeDeploymentChanges(poolId, shareClassId, shareToken, vaultAddress, tokenName);

        if (asyncRequestManager != address(0) && vaultAddress != address(0)) {
            _validateVaultRegistration(poolId, shareClassId, assetId, vaultAddress, tokenName);
        }

        _validateShareTokenVaultMapping(shareToken, assetId, tokenName);

        _validateDeployedV3Vault(shareToken, assetId, poolId, shareClassId, tokenName);

        if (asyncRequestManager != address(0)) {
            _validateBalanceSheetManager(poolId, asyncRequestManager, balanceSheet, tokenName);
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
            IAuth(address(shareToken)).wards(root),
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
            IShareToken linkedShareToken = ISpoke(spoke).shareToken(poolId, shareClassId);
            assertEq(
                address(linkedShareToken),
                address(shareToken),
                string(abi.encodePacked(tokenName, " share token should be linked to pool/share class in spoke"))
            );
        } else {
            address linkedShareToken = IV3_0_1_Spoke(spoke).shareToken(poolId, shareClassId);
            assertEq(
                linkedShareToken,
                address(shareToken),
                string(abi.encodePacked(tokenName, " share token should be linked to pool/share class in spoke"))
            );
        }

        if (isV3_1()) {
            assertTrue(
                ISpoke(spoke).isPoolActive(poolId),
                string(abi.encodePacked(tokenName, " pool should be active on spoke"))
            );
        } else {
            assertTrue(
                IV3_0_1_Spoke(spoke).isPoolActive(poolId),
                string(abi.encodePacked(tokenName, " pool should be active on spoke"))
            );
        }

        if (isV3_1()) {
            assertTrue(
                IVaultRegistry(vaultRegistry).isLinked(IVault(vaultAddress)),
                string(
                    abi.encodePacked("Deployed V3 ", tokenName, " vault should be marked as linked in VaultRegistry")
                )
            );
        } else {
            assertTrue(
                IV3_0_1_Spoke(spoke).isLinked(vaultAddress),
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
                IVaultRegistry(vaultRegistry).vault(poolId, shareClassId, assetId, IRequestManager(asyncRequestManager))
            );
        } else {
            actualVault = IV3_0_1_AsyncRequestManager(asyncRequestManager).vault(poolId, shareClassId, assetId);
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
            (assetAddress,) = ISpoke(spoke).idToAsset(assetId);
        } else {
            (assetAddress,) = IV3_0_1_Spoke(spoke).idToAsset(assetId);
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
            (assetAddress,) = ISpoke(spoke).idToAsset(assetId);
        } else {
            (assetAddress,) = IV3_0_1_Spoke(spoke).idToAsset(assetId);
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

    /// @notice Validates vaults for the current chain based on localCentrifugeId
    /// @dev Only called for production environments (testnets are skipped at the caller level)
    function _validateVaults() internal view {
        if (localCentrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID) {
            _validateEthereumVaults();
        } else if (localCentrifugeId == IntegrationConstants.BASE_CENTRIFUGE_ID) {
            _validateBaseVaults();
        } else if (localCentrifugeId == IntegrationConstants.ARBITRUM_CENTRIFUGE_ID) {
            _validateArbitrumVaults();
        } else if (localCentrifugeId == IntegrationConstants.AVAX_CENTRIFUGE_ID) {
            _validateAvalancheVaults();
        } else if (localCentrifugeId == IntegrationConstants.BNB_CENTRIFUGE_ID) {
            _validateBNBVaults();
        } else if (localCentrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            _validatePlumeVaults();
        }
    }

    /// @notice Internal helper to validate Ethereum vaults
    function _validateEthereumVaults() internal view {
        AssetId usdcAssetId;
        AssetId jtrsyAssetId;
        AssetId jaaaAssetId;
        if (isV3_1()) {
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.ETH_USDC, 0);
            jtrsyAssetId = ISpoke(spoke).assetToId(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, 0);
            jaaaAssetId = ISpoke(spoke).assetToId(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.ETH_USDC, 0);
            jtrsyAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.ETH_JTRSY_SHARE_TOKEN, 0);
            jaaaAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.ETH_JAAA_SHARE_TOKEN, 0);
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
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.BASE_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.BASE_USDC, 0);
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
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.AVAX_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.AVAX_USDC, 0);
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
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.ARBITRUM_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.ARBITRUM_USDC, 0);
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
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.BNB_USDC, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.BNB_USDC, 0);
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
            usdcAssetId = ISpoke(spoke).assetToId(IntegrationConstants.PLUME_USDC, 0);
            pusdAssetId = ISpoke(spoke).assetToId(IntegrationConstants.PLUME_PUSD, 0);
        } else {
            usdcAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.PLUME_USDC, 0);
            pusdAssetId = IV3_0_1_Spoke(spoke).assetToId(IntegrationConstants.PLUME_PUSD, 0);
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
