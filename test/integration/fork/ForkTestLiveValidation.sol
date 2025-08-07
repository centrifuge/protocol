// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ForkTestAsyncInvestments} from "./ForkTestInvestments.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Gateway} from "../../../src/common/Gateway.sol";
import {Guardian} from "../../../src/common/Guardian.sol";
import {IRoot} from "../../../src/common/interfaces/IRoot.sol";
import {MultiAdapter} from "../../../src/common/MultiAdapter.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageProcessor} from "../../../src/common/MessageProcessor.sol";
import {MessageDispatcher} from "../../../src/common/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../../../src/common/factories/PoolEscrowFactory.sol";

import {Hub} from "../../../src/hub/Hub.sol";
import {HubHelpers} from "../../../src/hub/HubHelpers.sol";

import {Spoke} from "../../../src/spoke/Spoke.sol";
import {BalanceSheet} from "../../../src/spoke/BalanceSheet.sol";
import {TokenFactory} from "../../../src/spoke/factories/TokenFactory.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {AsyncRequestManager} from "../../../src/vaults/AsyncRequestManager.sol";

import "forge-std/Test.sol";

import {AxelarAdapter} from "../../../src/adapters/AxelarAdapter.sol";
import {IntegrationConstants} from "../utils/IntegrationConstants.sol";
import {WormholeAdapter} from "../../../src/adapters/WormholeAdapter.sol";

/// @title ForkTestLiveValidation
/// @notice Contract for validating live contract permissions and state
/// @dev Currently inherits from ForkTestAsyncInvestments for investment flows and VM labeling.
///      VMLabeling functionality is inherited through ForkTestAsyncInvestments for improved debugging.
contract ForkTestLiveValidation is ForkTestAsyncInvestments {
    //----------------------------------------------------------------------------------------------
    // CORE PROTOCOL CONTRACTS
    //----------------------------------------------------------------------------------------------

    // Core system contracts
    address public root;
    address public guardian;
    address public gateway;
    address public gasService;
    address public tokenRecoverer;
    address public hubRegistry;
    address public accounting;
    address public holdings;
    address public shareClassManager;
    address public hub;
    address public hubHelpers;
    address public identityValuation;
    address public tokenFactory;
    address public balanceSheet;
    address public spoke;
    address public contractUpdater;
    address public router;
    address public routerEscrow;
    address public globalEscrow;
    address public asyncRequestManager;
    address public syncManager;
    address public wormholeAdapter;
    address public axelarAdapter;
    address public messageProcessor;
    address public messageDispatcher;
    address public multiAdapter;
    address public poolEscrowFactory;
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
    // VAULT CONTRACTS
    //----------------------------------------------------------------------------------------------

    address public ethJaaaVault;
    address public ethJtrsyVault;
    address public ethDejaaaVault;
    address public ethDejtrsyVault;
    address public avaxJaaaVault;

    //----------------------------------------------------------------------------------------------
    // SHARE TOKEN CONTRACTS
    //----------------------------------------------------------------------------------------------

    address public ethJaaaShareToken;
    address public ethJtrsyShareToken;
    address public ethDejtrsyShareToken;
    address public ethDejaaaShareToken;
    address public avaxJaaaShareToken;
    address public avaxJtrsyShareToken;

    //----------------------------------------------------------------------------------------------
    // SETUP
    //----------------------------------------------------------------------------------------------

    uint16 internal localCentrifugeId;

    function setUp() public virtual override {
        super.setUp();
        _initializeContractAddresses();
        // Setup VM labels for improved test output readability
        _setupVMLabels();
    }

    function _configureChain(uint16 localCentrifugeId_, address adminSafe_) internal {
        localCentrifugeId = localCentrifugeId_;
        adminSafe = adminSafe_;
    }

    /// @notice Initialize all contract addresses from IntegrationConstants
    /// @dev Virtual function to allow child contracts to override specific addresses
    function _initializeContractAddresses() internal virtual {
        // Core system contracts
        root = IntegrationConstants.ROOT;
        guardian = IntegrationConstants.GUARDIAN;
        gateway = IntegrationConstants.GATEWAY;
        gasService = IntegrationConstants.GAS_SERVICE;
        tokenRecoverer = IntegrationConstants.TOKEN_RECOVERER;
        hubRegistry = IntegrationConstants.HUB_REGISTRY;
        accounting = IntegrationConstants.ACCOUNTING;
        holdings = IntegrationConstants.HOLDINGS;
        shareClassManager = IntegrationConstants.SHARE_CLASS_MANAGER;
        hub = IntegrationConstants.HUB;
        hubHelpers = IntegrationConstants.HUB_HELPERS;
        identityValuation = IntegrationConstants.IDENTITY_VALUATION;
        tokenFactory = IntegrationConstants.TOKEN_FACTORY;
        balanceSheet = IntegrationConstants.BALANCE_SHEET;
        spoke = IntegrationConstants.SPOKE;
        contractUpdater = IntegrationConstants.CONTRACT_UPDATER;
        router = IntegrationConstants.ROUTER;
        routerEscrow = IntegrationConstants.ROUTER_ESCROW;
        globalEscrow = IntegrationConstants.GLOBAL_ESCROW;
        asyncRequestManager = IntegrationConstants.ASYNC_REQUEST_MANAGER;
        syncManager = IntegrationConstants.SYNC_MANAGER;
        wormholeAdapter = IntegrationConstants.WORMHOLE_ADAPTER;
        axelarAdapter = IntegrationConstants.AXELAR_ADAPTER;
        messageProcessor = IntegrationConstants.MESSAGE_PROCESSOR;
        messageDispatcher = IntegrationConstants.MESSAGE_DISPATCHER;
        multiAdapter = IntegrationConstants.MULTI_ADAPTER;
        poolEscrowFactory = IntegrationConstants.POOL_ESCROW_FACTORY;
        adminSafe = IntegrationConstants.ETH_ADMIN_SAFE;

        // Factory contracts
        asyncVaultFactory = IntegrationConstants.ASYNC_VAULT_FACTORY;
        syncDepositVaultFactory = IntegrationConstants.SYNC_DEPOSIT_VAULT_FACTORY;

        // Hook contracts
        freezeOnlyHook = IntegrationConstants.FREEZE_ONLY_HOOK;
        fullRestrictionsHook = IntegrationConstants.FULL_RESTRICTIONS_HOOK;
        freelyTransferableHook = IntegrationConstants.FREELY_TRANSFERABLE_HOOK;
        redemptionRestrictionsHook = IntegrationConstants.REDEMPTION_RESTRICTIONS_HOOK;

        // Vault contracts
        ethJaaaVault = IntegrationConstants.ETH_JAAA_VAULT;
        ethJtrsyVault = IntegrationConstants.ETH_JTRSY_VAULT;
        ethDejaaaVault = IntegrationConstants.ETH_DEJAA_USDC_VAULT;
        ethDejtrsyVault = IntegrationConstants.ETH_DEJTRSY_USDC_VAULT;
        avaxJaaaVault = IntegrationConstants.AVAX_JAAA_USDC_VAULT;

        // Share token contracts
        ethJaaaShareToken = IntegrationConstants.ETH_JAAA_SHARE_TOKEN;
        ethJtrsyShareToken = IntegrationConstants.ETH_JTRSY_SHARE_TOKEN;
        ethDejtrsyShareToken = IntegrationConstants.ETH_DEJTRSY_SHARE_TOKEN;
        ethDejaaaShareToken = IntegrationConstants.ETH_DEJAAA_SHARE_TOKEN;
        avaxJaaaShareToken = IntegrationConstants.AVAX_JAAA_SHARE_TOKEN;
        avaxJtrsyShareToken = IntegrationConstants.AVAX_JTRSY_SHARE_TOKEN;

        // Multichain config
        localCentrifugeId = IntegrationConstants.ETH_CENTRIFUGE_ID;
    }

    //----------------------------------------------------------------------------------------------
    // VALIDATION FUNCTIONS
    //----------------------------------------------------------------------------------------------
    function test_validateCompleteDeployment() public virtual {
        validateDeployment();
    }

    /// @notice Validates wards and filings of core protocol contracts, vaults and share tokens
    function validateDeployment() public view {
        _validateV3RootPermissions();
        _validateContractWardRelationships();
        _validateFileConfigurations();
        _validateEndorsements();
        _validateGuardianAdapterConfigurations();

        // TODO: Solve in follow-up PR for all chains, right now only ETH -> x support
        if (localCentrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID) {
            _validateAdapterSourceDestinationMappings();
        }
    }

    /// @notice Validates that root has ward permissions on all core protocol contracts, vaults, and share tokens
    function _validateV3RootPermissions() internal view virtual {
        // From CommonDeployer
        _validateRootWard(tokenRecoverer);

        // From HubDeployer
        _validateRootWard(hubRegistry);
        _validateRootWard(accounting);
        _validateRootWard(holdings);
        _validateRootWard(shareClassManager);
        _validateRootWard(hub);
        _validateRootWard(hubHelpers);

        // From SpokeDeployer
        _validateRootWard(spoke);
        _validateRootWard(balanceSheet);
        _validateRootWard(tokenFactory);
        _validateRootWard(contractUpdater);

        // From VaultsDeployer
        _validateRootWard(router);
        _validateRootWard(asyncRequestManager);
        _validateRootWard(syncManager);
        _validateRootWard(routerEscrow);
        _validateRootWard(globalEscrow);
        _validateRootWard(asyncVaultFactory);
        _validateRootWard(syncDepositVaultFactory);

        // From ValuationsDeployer
        _validateRootWard(identityValuation);

        // From HooksDeployer
        _validateRootWard(freezeOnlyHook);
        _validateRootWard(fullRestrictionsHook);
        _validateRootWard(freelyTransferableHook);
        _validateRootWard(redemptionRestrictionsHook);

        // From VaultsDeployer
        _validateRootWard(wormholeAdapter);
        _validateRootWard(axelarAdapter);

        // TODO: In later PR, move to helper for network-dependent checks
        if (localCentrifugeId == IntegrationConstants.ETH_CENTRIFUGE_ID) {
            _validateRootWard(ethJaaaVault);
            _validateRootWard(ethJtrsyVault);
            _validateRootWard(ethDejaaaVault);
            _validateRootWard(ethDejtrsyVault);

            _validateRootWard(ethJaaaShareToken);
            _validateRootWard(ethJtrsyShareToken);
            _validateRootWard(ethDejtrsyShareToken);
            _validateRootWard(ethDejaaaShareToken);
        } else if (localCentrifugeId == IntegrationConstants.AVAX_CENTRIFUGE_ID) {
            _validateRootWard(ethJtrsyVault); // same address
            _validateRootWard(avaxJaaaVault);

            _validateRootWard(avaxJaaaShareToken);
            _validateRootWard(avaxJtrsyShareToken);
        } else if (localCentrifugeId == IntegrationConstants.BASE_CENTRIFUGE_ID) {
            // Base uses deterministic addresses, so same as ETH_DEJAA_JAAA_VAULT
            _validateRootWard(IntegrationConstants.ETH_DEJAA_JAAA_VAULT);

            // Validate corresponding share token (deterministic deployment)
            _validateRootWard(ethDejaaaShareToken);
        }
    }

    /// @notice Optimized ROOT ward validation using VM labels
    function _validateRootWard(address contractAddr) internal view {
        require(contractAddr.code.length > 0, string(abi.encodePacked("Contract has no code: ", contractAddr)));
        assertEq(IAuth(contractAddr).wards(root), 1);
    }

    /// @notice Validates all contract-to-contract ward relationships based on deployment scripts
    function _validateContractWardRelationships() internal view {
        // CommonDeployer
        _validateWard(root, guardian);
        _validateWard(root, tokenRecoverer);
        _validateWard(root, messageProcessor);
        _validateWard(root, messageDispatcher);
        _validateWard(gateway, root);
        _validateWard(gateway, messageDispatcher);
        _validateWard(gateway, multiAdapter);
        _validateWard(gateway, hub);
        _validateWard(gateway, spoke);
        _validateWard(gateway, balanceSheet);
        _validateWard(gateway, router);
        _validateWard(multiAdapter, root);
        _validateWard(multiAdapter, guardian);
        _validateWard(multiAdapter, gateway);
        _validateWard(messageDispatcher, root);
        _validateWard(messageDispatcher, guardian);
        _validateWard(messageDispatcher, hub);
        _validateWard(messageDispatcher, hubHelpers);
        _validateWard(messageDispatcher, spoke);
        _validateWard(messageDispatcher, balanceSheet);
        _validateWard(messageProcessor, root);
        _validateWard(messageProcessor, gateway);
        _validateWard(tokenRecoverer, root);
        _validateWard(tokenRecoverer, messageDispatcher);
        _validateWard(tokenRecoverer, messageProcessor);
        _validateWard(poolEscrowFactory, root);
        _validateWard(poolEscrowFactory, hub);
        _validateWard(poolEscrowFactory, spoke);

        // HubDeployer
        _validateWard(hubRegistry, hub);
        _validateWard(holdings, hub);
        _validateWard(accounting, hub);
        _validateWard(shareClassManager, hub);
        _validateWard(hubHelpers, hub);
        _validateWard(hub, messageProcessor);
        _validateWard(hub, messageDispatcher);
        _validateWard(hub, guardian);
        _validateWard(accounting, hubHelpers);
        _validateWard(shareClassManager, hubHelpers);

        // SpokeDeployer
        _validateWard(tokenFactory, spoke);
        _validateWard(spoke, messageProcessor);
        _validateWard(spoke, messageDispatcher);
        _validateWard(balanceSheet, messageProcessor);
        _validateWard(balanceSheet, messageDispatcher);
        _validateWard(contractUpdater, messageProcessor);
        _validateWard(contractUpdater, messageDispatcher);

        // VaultsDeployer
        _validateWard(asyncVaultFactory, spoke);
        _validateWard(syncDepositVaultFactory, spoke);
        _validateWard(asyncRequestManager, spoke);
        _validateWard(syncManager, contractUpdater);
        _validateWard(globalEscrow, asyncRequestManager);
        _validateWard(routerEscrow, router);
        // TODO: Ensure Missing syncManager <- syncDepositVaultFactory relationship is expected
        _validateWard(asyncRequestManager, syncDepositVaultFactory);
        _validateWard(asyncRequestManager, asyncVaultFactory);

        // HooksDeployer
        _validateWard(freezeOnlyHook, spoke);
        _validateWard(fullRestrictionsHook, spoke);
        _validateWard(freelyTransferableHook, spoke);
        _validateWard(redemptionRestrictionsHook, spoke);
    }

    /// @notice Validates file configurations set during deployment
    function _validateFileConfigurations() internal view {
        // CommonDeployer configs
        assertEq(address(Gateway(payable(gateway)).processor()), messageProcessor, "messageProcessor mismatch");
        assertEq(address(Gateway(payable(gateway)).adapter()), multiAdapter, "multiAdapter mismatch");
        assertEq(PoolEscrowFactory(poolEscrowFactory).gateway(), gateway, "gateway mismatch");
        assertEq(address(Guardian(guardian).safe()), adminSafe, "adminSafe mismatch");

        // HubDeployer Configs
        assertEq(address(MessageProcessor(messageProcessor).hub()), hub, "messageProcessor.hub mismatch");
        assertEq(address(MessageDispatcher(messageDispatcher).hub()), hub, "messageDispatcher.hub mismatch");
        assertEq(address(Hub(hub).sender()), messageDispatcher, "hub.sender mismatch");
        assertEq(address(Hub(hub).poolEscrowFactory()), poolEscrowFactory, "hub.poolEscrowFactory mismatch");
        assertEq(address(Guardian(guardian).hub()), hub, "guardian.hub mismatch");
        assertEq(address(HubHelpers(hubHelpers).hub()), hub, "hubhelpers.hub mismatch");

        // SpokeDeployer configs
        assertEq(address(MessageDispatcher(messageDispatcher).spoke()), spoke, "messageDispatcher.spoke mismatch");
        assertEq(
            address(MessageDispatcher(messageDispatcher).balanceSheet()),
            balanceSheet,
            "messageDispatcher.balanceSheet mismatch"
        );
        assertEq(
            address(MessageDispatcher(messageDispatcher).contractUpdater()),
            contractUpdater,
            "messageDispatcher.contractUpdater mismatch"
        );

        assertEq(address(MessageProcessor(messageProcessor).spoke()), spoke, "messageProcessor.spoke mismatch");
        assertEq(
            address(MessageProcessor(messageProcessor).balanceSheet()),
            balanceSheet,
            "messageProcessor.balanceSheet mismatch"
        );
        assertEq(
            address(MessageProcessor(messageProcessor).contractUpdater()),
            contractUpdater,
            "messageProcessor.contractUpdater mismatch"
        );

        assertEq(address(Spoke(spoke).gateway()), gateway, "spoke.gateway mismatch");
        assertEq(address(Spoke(spoke).sender()), messageDispatcher, "spoke.messageDispatcher mismatch");
        assertEq(address(Spoke(spoke).poolEscrowFactory()), poolEscrowFactory, "spoke.poolEscrowFactory mismatch");

        assertEq(address(BalanceSheet(balanceSheet).spoke()), spoke, "balanceSheet.spoke mismatch");
        assertEq(
            address(BalanceSheet(balanceSheet).sender()), messageDispatcher, "balanceSheet.messageDispatcher mismatch"
        );
        assertEq(address(BalanceSheet(balanceSheet).gateway()), gateway, "balanceSheet.gateway mismatch");
        assertEq(
            address(BalanceSheet(balanceSheet).poolEscrowProvider()),
            poolEscrowFactory,
            "balanceSheet.poolEscrowFactory mismatch"
        );

        assertEq(
            PoolEscrowFactory(poolEscrowFactory).balanceSheet(), balanceSheet, "poolEscrowFactory.balanceSheet mismatch"
        );

        TokenFactory factory = TokenFactory(tokenFactory);
        assertEq(factory.tokenWards(0), spoke, "tokenfactory.spoke ward mismatch");
        assertEq(factory.tokenWards(1), balanceSheet, "TokenFactory.balanceSheet ward mismatch");

        // VaultsDeployer configs
        assertEq(address(AsyncRequestManager(asyncRequestManager).spoke()), spoke, "asyncRequestManager.spoke mismatch");
        assertEq(
            address(AsyncRequestManager(asyncRequestManager).balanceSheet()),
            balanceSheet,
            "asyncRequestManager.balanceSheet mismatch"
        );

        assertEq(address(SyncManager(syncManager).spoke()), spoke, "syncManager.spoke mismatch");
        assertEq(address(SyncManager(syncManager).balanceSheet()), balanceSheet, "syncManager.balanceSheet mismatch");
    }

    /// @notice Validates endorsements from Root
    function _validateEndorsements() internal view {
        // From VaultsDeployer
        assertEq(IRoot(root).endorsements(asyncRequestManager), 1, "AsyncRequestManager not endorsed by Root");
        assertEq(IRoot(root).endorsements(globalEscrow), 1, "GlobalEscrow not endorsed by Root");
        assertEq(IRoot(root).endorsements(router), 1, "VaultRouter not endorsed by Root");

        // From SpokeDeployer
        assertEq(IRoot(root).endorsements(balanceSheet), 1, "BalanceSheet not endorsed by Root");
    }

    /// @notice Validates Guardian adapter configurations for all connected chains
    function _validateGuardianAdapterConfigurations() internal view {
        MultiAdapter multiAdapterContract = MultiAdapter(multiAdapter);

        for (uint16 centrifugeId = 1; centrifugeId <= IntegrationConstants.BNB_CENTRIFUGE_ID; centrifugeId++) {
            _validateMultiAdapterConfiguration(multiAdapterContract, centrifugeId);
        }
    }

    /// @notice Validates adapter source and destination mappings
    function _validateAdapterSourceDestinationMappings() internal view {
        WormholeAdapter wormholeAdapterContract = WormholeAdapter(wormholeAdapter);
        AxelarAdapter axelarAdapterContract = AxelarAdapter(axelarAdapter);

        _validateWormholeMapping(
            wormholeAdapterContract,
            IntegrationConstants.BASE_WORMHOLE_ID,
            IntegrationConstants.BASE_CENTRIFUGE_ID,
            "Base"
        );

        _validateWormholeMapping(
            wormholeAdapterContract,
            IntegrationConstants.ARBITRUM_WORMHOLE_ID,
            IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
            "Arbitrum"
        );

        _validateWormholeMapping(
            wormholeAdapterContract,
            IntegrationConstants.PLUME_WORMHOLE_ID,
            IntegrationConstants.PLUME_CENTRIFUGE_ID,
            "Plume"
        );

        _validateWormholeMapping(
            wormholeAdapterContract,
            IntegrationConstants.AVAX_WORMHOLE_ID,
            IntegrationConstants.AVAX_CENTRIFUGE_ID,
            "Avalanche"
        );

        _validateWormholeMapping(
            wormholeAdapterContract, IntegrationConstants.BNB_WORMHOLE_ID, IntegrationConstants.BNB_CENTRIFUGE_ID, "BNB"
        );

        _validateAxelarMapping(
            axelarAdapterContract, IntegrationConstants.BASE_AXELAR_ID, IntegrationConstants.BASE_CENTRIFUGE_ID, "Base"
        );

        _validateAxelarMapping(
            axelarAdapterContract,
            IntegrationConstants.ARBITRUM_AXELAR_ID,
            IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
            "Arbitrum"
        );

        _validateAxelarMapping(
            axelarAdapterContract,
            IntegrationConstants.AVAX_AXELAR_ID,
            IntegrationConstants.AVAX_CENTRIFUGE_ID,
            "Avalanche"
        );

        _validateAxelarMapping(
            axelarAdapterContract, IntegrationConstants.BNB_AXELAR_ID, IntegrationConstants.BNB_CENTRIFUGE_ID, "BNB"
        );
    }

    /// @notice Helper function to validate MultiAdapter configuration for a specific chain
    function _validateMultiAdapterConfiguration(MultiAdapter multiAdapterContract, uint16 centrifugeId) internal view {
        if (
            localCentrifugeId == centrifugeId
                || localCentrifugeId != IntegrationConstants.ETH_CENTRIFUGE_ID
                    && centrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID
        ) {
            return;
        }

        // Determine expected adapter count based on chain (only Plume doesn't have Axelar)
        bool hasAxelar = centrifugeId != IntegrationConstants.PLUME_CENTRIFUGE_ID;
        uint8 expectedQuorum = hasAxelar ? 2 : 1;

        // Verify quorum matches expected adapter count
        uint8 actualQuorum = multiAdapterContract.quorum(centrifugeId);
        assertEq(actualQuorum, expectedQuorum);

        // Verify first adapter is always Wormhole (primary)
        IAdapter primaryAdapter = multiAdapterContract.adapters(centrifugeId, 0);
        assertEq(address(primaryAdapter), wormholeAdapter);

        if (hasAxelar) {
            // Verify second adapter is Axelar
            IAdapter secondaryAdapter = multiAdapterContract.adapters(centrifugeId, 1);
            assertEq(address(secondaryAdapter), axelarAdapter);
        }
    }

    /// @notice Helper function to validate Wormhole adapter source/destination mappings
    function _validateWormholeMapping(
        WormholeAdapter wormholeAdapterContract,
        uint16 wormholeId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source mapping (incoming from remote chain)
        (uint16 sourceCentrifugeId, address sourceAddr) = wormholeAdapterContract.sources(wormholeId);
        assertEq(
            sourceCentrifugeId,
            centrifugeId,
            string(abi.encodePacked("WormholeAdapter source centrifugeId mismatch for ", chainName))
        );
        assertEq(
            sourceAddr,
            wormholeAdapter,
            string(abi.encodePacked("WormholeAdapter source address mismatch for ", chainName))
        );

        // Validate destination mapping (outgoing to remote chain)
        (uint16 destWormholeId, address destAddr) = wormholeAdapterContract.destinations(centrifugeId);
        assertEq(
            destWormholeId,
            wormholeId,
            string(abi.encodePacked("WormholeAdapter destination wormholeId mismatch for ", chainName))
        );
        assertEq(
            destAddr,
            wormholeAdapter,
            string(abi.encodePacked("WormholeAdapter destination address mismatch for ", chainName))
        );
    }

    /// @notice Helper function to validate Axelar adapter source/destination mappings
    function _validateAxelarMapping(
        AxelarAdapter axelarAdapterContract,
        string memory axelarId,
        uint16 centrifugeId,
        string memory chainName
    ) internal view {
        // Validate source mapping (incoming from remote chain)
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
            string(abi.encodePacked("AxelarAdapter source addressHash mismatch for ", chainName))
        );

        // Validate destination mapping (outgoing to remote chain)
        (string memory destAxelarId, string memory destAddr) = axelarAdapterContract.destinations(centrifugeId);
        assertEq(
            keccak256(bytes(destAxelarId)),
            keccak256(bytes(axelarId)),
            string(abi.encodePacked("AxelarAdapter destination axelarId mismatch for ", chainName))
        );
        assertEq(
            keccak256(bytes(destAddr)),
            keccak256(abi.encodePacked(vm.toString(axelarAdapter))),
            string(abi.encodePacked("AxelarAdapter destination address mismatch for ", chainName))
        );
    }

    function _validateWard(address wardedContract, address wardHolder) internal view {
        assertEq(IAuth(wardedContract).wards(wardHolder), 1);
    }
}
