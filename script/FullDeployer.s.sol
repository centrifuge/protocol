// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";

import {Hub} from "../src/core/hub/Hub.sol";
import {Envoy} from "../src/core/utils/Envoy.sol";
import {Spoke} from "../src/core/spoke/Spoke.sol";
import {Holdings} from "../src/core/hub/Holdings.sol";
import {Accounting} from "../src/core/hub/Accounting.sol";
import {Gateway} from "../src/core/messaging/Gateway.sol";
import {HubHandler} from "../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../src/core/hub/HubRegistry.sol";
import {SpokeHandler} from "../src/core/spoke/SpokeHandler.sol";
import {SnapshotQueue} from "../src/core/spoke/SnapshotQueue.sol";
import {SpokeRegistry} from "../src/core/spoke/SpokeRegistry.sol";
import {MultiAdapter} from "../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../src/core/hub/ShareClassManager.sol";
import {MessageProcessor} from "../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../src/core/spoke/factories/PoolEscrowFactory.sol";
import {ContractUpdaterForwarder} from "../src/core/utils/ContractUpdaterForwarder.sol";

import {Root} from "../src/admin/Root.sol";
import {GasService} from "../src/admin/GasService.sol";
import {ISafe} from "../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../src/token/hooks/FreezeOnly.sol";
import {NAVManager} from "../src/hooks/accounting/NAVManager.sol";
import {FullRestrictions} from "../src/token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../src/token/hooks/FreelyTransferable.sol";
import {BridgeCircuitBreaker} from "../src/hooks/bridge/BridgeCircuitBreaker.sol";
import {SimplePriceManager} from "../src/hooks/accounting/SimplePriceManager.sol";
import {RedemptionRestrictions} from "../src/token/hooks/RedemptionRestrictions.sol";

import {QueueManager} from "../src/managers/spoke/QueueManager.sol";
import {OnOffRampFactory} from "../src/managers/spoke/OnOffRamp.sol";
import {ScriptHelpers} from "../src/managers/spoke/ScriptHelpers.sol";
import {AccountingToken} from "../src/managers/spoke/AccountingToken.sol";
import {FlashLoanHelper} from "../src/managers/spoke/FlashLoanHelper.sol";
import {AdapterFailover} from "../src/managers/adapters/AdapterFailover.sol";
import {ApprovalGuard} from "../src/managers/spoke/guards/ApprovalGuard.sol";
import {SlippageGuard} from "../src/managers/spoke/guards/SlippageGuard.sol";
import {CircuitBreakerGuard} from "../src/managers/spoke/guards/CircuitBreakerGuard.sol";
import {IOnchainPMFactory} from "../src/managers/spoke/interfaces/IOnchainPMFactory.sol";

import {OracleValuation} from "../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../src/vaults/SyncManager.sol";
import {VaultRouter} from "../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import {VmSafe} from "forge-std/Vm.sol";

import {TokenBridge} from "../src/bridge/TokenBridge.sol";
import {SubsidyManager} from "../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {ChainlinkAdapter} from "../src/adapters/ChainlinkAdapter.sol";
import {HyperlaneAdapter} from "../src/adapters/HyperlaneAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../src/utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../src/token/ShareTokenRegistrar.sol";
import {
    Constants,
    CoreReport,
    CoreActionBatcher,
    NonCoreActionBatcher,
    AdapterActionBatcher,
    NonCoreReport,
    AdaptersReport,
    AdapterConnections,
    SetConfigParam
} from "../src/deployment/ActionBatchers.sol";

string constant V3_1 = "v3.1";
string constant V3_1_1 = "v3.1.1";
string constant V3_2 = "v3.2";
string constant V3_3 = "v3.3";

struct AxelarInput {
    bool shouldDeploy;
    address gateway;
    address gasService;
}

struct LayerZeroInput {
    bool shouldDeploy;
    address endpoint;
    address delegate;
    // Pre-computed LayerZero ULN config
    // Should contain SetConfigParam[] for both send and receive libraries
    // The order of this array must be the same as the connections
    SetConfigParam[] configParams;
}

struct ChainlinkInput {
    bool shouldDeploy;
    address ccipRouter;
}

struct HyperlaneInput {
    bool shouldDeploy;
    address mailbox;
    address ism;
}

struct AdaptersInput {
    LayerZeroInput layerZero;
    AxelarInput axelar;
    ChainlinkInput chainlink;
    HyperlaneInput hyperlane;
    AdapterConnections[] connections;
}

struct DeployerInput {
    uint16 centrifugeId;
    string suffix;
    uint8[32] txLimits;
    ISafe protocolSafe;
    ISafe opsSafe;
    AdaptersInput adapters;
}

contract FullDeployer is BaseDeployer, Constants {
    uint256 public constant DELAY = 48 hours;

    Root public root;
    ProtocolGuardian public protocolGuardian;
    OpsGuardian public opsGuardian;
    GasService public gasService;

    Gateway public gateway;
    MultiAdapter public multiAdapter;

    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    Spoke public spoke;
    SnapshotQueue public snapshotQueue;
    ShareTokenRegistrar public shareTokenRegistrar;
    ContractUpdater public contractUpdater;
    SpokeRegistry public spokeRegistry;
    SpokeHandler public spokeHandler;
    ContractUpdaterForwarder public contractUpdaterForwarder;
    Envoy public envoy;
    PoolEscrowFactory public poolEscrowFactory;

    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    HubHandler public hubHandler;
    Hub public hub;

    SubsidyManager public subsidyManager;
    RefundEscrowFactory public refundEscrowFactory;
    AsyncVaultFactory public asyncVaultFactory;
    AsyncRequestManager public asyncRequestManager;
    SyncDepositVaultFactory public syncDepositVaultFactory;
    SyncManager public syncManager;
    VaultRouter public vaultRouter;

    TokenBridge public tokenBridge;
    BridgeCircuitBreaker public bridgeCircuitBreaker;

    FreezeOnly public freezeOnlyHook;
    FullRestrictions public fullRestrictionsHook;
    FreelyTransferable public freelyTransferableHook;
    RedemptionRestrictions public redemptionRestrictionsHook;

    QueueManager public queueManager;
    AdapterFailover public adapterFailover;
    AccountingToken public accountingToken;
    ScriptHelpers public scriptHelpers;
    FlashLoanHelper public flashLoanHelper;
    IOnchainPMFactory public onchainPMFactory;
    OnOffRampFactory public onOffRampFactory;
    ApprovalGuard public approvalGuard;
    CircuitBreakerGuard public circuitBreakerGuard;
    SlippageGuard public slippageGuard;
    BatchRequestManager public batchRequestManager;

    IdentityValuation public identityValuation;
    OracleValuation public oracleValuation;

    NAVManager public navManager;
    SimplePriceManager public simplePriceManager;

    ChainlinkAdapter chainlinkAdapter;
    AxelarAdapter axelarAdapter;
    LayerZeroAdapter layerZeroAdapter;
    HyperlaneAdapter hyperlaneAdapter;

    CoreActionBatcher public coreBatcher;
    NonCoreActionBatcher public nonCoreBatcher;
    AdapterActionBatcher public adapterBatcher;

    function deployFull(DeployerInput memory input, address deployer_) public {
        _init(input.suffix, deployer_);

        address coreBatcherAddr = previewCreate3Address("coreBatcher", V3_1);
        address nonCoreBatcherAddr = previewCreate3Address("nonCoreBatcher", V3_1);
        address adapterBatcherAddr = previewCreate3Address("adapterBatcher", V3_1);

        _deployCore(coreBatcherAddr, input);
        coreBatcher = CoreActionBatcher(
            create3(
                createSalt("coreBatcher", V3_1),
                abi.encodePacked(
                    type(CoreActionBatcher).creationCode,
                    abi.encode(coreReport(), input.protocolSafe, input.opsSafe, adapterBatcherAddr, nonCoreBatcherAddr)
                )
            )
        );

        _deployNonCore(nonCoreBatcherAddr, input.centrifugeId);
        nonCoreBatcher = NonCoreActionBatcher(
            create3(
                createSalt("nonCoreBatcher", V3_1),
                abi.encodePacked(type(NonCoreActionBatcher).creationCode, abi.encode(nonCoreReport()))
            )
        );

        _deployAdapters(adapterBatcherAddr, input.adapters);
        adapterBatcher = AdapterActionBatcher(
            create3(
                createSalt("adapterBatcher", V3_1),
                abi.encodePacked(
                    type(AdapterActionBatcher).creationCode,
                    abi.encode(
                        adaptersReport(),
                        input.protocolSafe,
                        input.adapters.connections,
                        input.adapters.layerZero.configParams,
                        input.adapters.layerZero.delegate,
                        vm.toString(address(axelarAdapter)),
                        input.adapters.hyperlane.ism
                    )
                )
            )
        );

        // NOTE. Coverage compiles without optimizations.
        // This means that the gas costs are higher than the calibrated gasService limits,
        // causing message processing to silently fail (e.g. PoolEscrow creation via CREATE).
        // We mock messageProcessingGasLimit with a higher value large enough for unoptimized code.
        if (vm.isContext(VmSafe.ForgeContext.Coverage)) {
            vm.mockCall(
                address(gasService),
                abi.encodeWithSelector(GasService.messageProcessingGasLimit.selector),
                abi.encode(uint128(30_000_000))
            );
        }
    }

    function _deployCore(address batcher, DeployerInput memory input) internal {
        address tokenBridgeAddr = previewCreate3Address("tokenBridge", V3_3);

        // Admin
        root = Root(
            create3(createSalt("root", V3_1), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, batcher)))
        );

        gasService = GasService(
            create3(
                createSalt("gasService", V3_3),
                abi.encodePacked(type(GasService).creationCode, abi.encode(input.txLimits, input.centrifugeId))
            )
        );

        // Utils
        contractUpdater = ContractUpdater(
            create3(
                createSalt("contractUpdater", V3_3),
                abi.encodePacked(type(ContractUpdater).creationCode, abi.encode(batcher))
            )
        );

        // Messaging
        gateway = Gateway(
            create3(
                createSalt("gateway", V3_3),
                abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, root, batcher))
            )
        );

        multiAdapter = MultiAdapter(
            create3(
                createSalt("multiAdapter", V3_3),
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, batcher))
            )
        );

        envoy =
            Envoy(create3(createSalt("envoy", V3_3), abi.encodePacked(type(Envoy).creationCode, abi.encode(batcher))));

        contractUpdaterForwarder = ContractUpdaterForwarder(
            create3(
                createSalt("contractUpdaterForwarder", V3_3),
                abi.encodePacked(
                    type(ContractUpdaterForwarder).creationCode, abi.encode(address(envoy), contractUpdater)
                )
            )
        );

        messageProcessor = MessageProcessor(
            create3(
                createSalt("messageProcessor", V3_3),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, batcher))
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                createSalt("messageDispatcher", V3_3),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode, abi.encode(input.centrifugeId, root, gateway, batcher)
                )
            )
        );

        // Spoke
        shareTokenRegistrar = ShareTokenRegistrar(
            create3(
                createSalt("shareTokenRegistrar", V3_3),
                abi.encodePacked(type(ShareTokenRegistrar).creationCode, abi.encode(root, batcher))
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3(
                createSalt("poolEscrowFactory", V3_3),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(root, batcher))
            )
        );

        spokeRegistry = SpokeRegistry(
            create3(
                createSalt("spokeRegistry", V3_3),
                abi.encodePacked(type(SpokeRegistry).creationCode, abi.encode(batcher))
            )
        );

        snapshotQueue = SnapshotQueue(
            create3(
                createSalt("snapshotQueue", V3_3),
                abi.encodePacked(type(SnapshotQueue).creationCode, abi.encode(batcher))
            )
        );

        spoke = Spoke(
            create3(
                createSalt("spoke", V3_3),
                abi.encodePacked(
                    type(Spoke).creationCode,
                    abi.encode(gateway, snapshotQueue, spokeRegistry, poolEscrowFactory, batcher)
                )
            )
        );

        spokeHandler = SpokeHandler(
            create3(
                createSalt("spokeHandler", V3_3),
                abi.encodePacked(type(SpokeHandler).creationCode, abi.encode(spokeRegistry, poolEscrowFactory, batcher))
            )
        );

        // Hub
        hubRegistry = HubRegistry(
            create3(
                createSalt("hubRegistry", V3_3), abi.encodePacked(type(HubRegistry).creationCode, abi.encode(batcher))
            )
        );

        accounting = Accounting(
            create3(
                createSalt("accounting", V3_3), abi.encodePacked(type(Accounting).creationCode, abi.encode(batcher))
            )
        );

        holdings = Holdings(
            create3(
                createSalt("holdings", V3_3),
                abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        shareClassManager = ShareClassManager(
            create3(
                createSalt("shareClassManager", V3_3),
                abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        hub = Hub(
            create3(
                createSalt("hub", V3_3),
                abi.encodePacked(
                    type(Hub).creationCode,
                    abi.encode(gateway, holdings, accounting, hubRegistry, multiAdapter, shareClassManager, batcher)
                )
            )
        );

        hubHandler = HubHandler(
            create3(
                createSalt("hubHandler", V3_3),
                abi.encodePacked(
                    type(HubHandler).creationCode, abi.encode(hub, holdings, hubRegistry, shareClassManager, batcher)
                )
            )
        );

        // Admin (depends on core contracts)
        protocolGuardian = ProtocolGuardian(
            create3(
                createSalt("protocolGuardian", V3_3),
                abi.encodePacked(
                    type(ProtocolGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, messageDispatcher, TokenBridge(tokenBridgeAddr))
                )
            )
        );

        opsGuardian = OpsGuardian(
            create3(
                createSalt("opsGuardian", V3_3),
                abi.encodePacked(
                    type(OpsGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), hub, TokenBridge(tokenBridgeAddr), multiAdapter)
                )
            )
        );
    }

    function _deployNonCore(address batcher, uint16 centrifugeId_) internal {
        refundEscrowFactory = RefundEscrowFactory(
            create3(
                createSalt("refundEscrowFactory", V3_1),
                abi.encodePacked(type(RefundEscrowFactory).creationCode, abi.encode(batcher))
            )
        );

        subsidyManager = SubsidyManager(
            create3(
                createSalt("subsidyManager", V3_3),
                abi.encodePacked(type(SubsidyManager).creationCode, abi.encode(refundEscrowFactory, batcher))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(create3(
                    createSalt("asyncRequestManager", V3_3),
                    abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(subsidyManager, batcher))
                ))
        );

        syncManager = SyncManager(
            create3(
                createSalt("syncManager", V3_3), abi.encodePacked(type(SyncManager).creationCode, abi.encode(batcher))
            )
        );

        vaultRouter = VaultRouter(
            create3(
                createSalt("vaultRouter", V3_3),
                abi.encodePacked(type(VaultRouter).creationCode, abi.encode(spoke, spokeRegistry, batcher))
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3(
                createSalt("asyncVaultFactory", V3_3),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, batcher)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                createSalt("syncDepositVaultFactory", V3_3),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, batcher)
                )
            )
        );

        freezeOnlyHook = FreezeOnly(
            create3(
                createSalt("freezeOnlyHook", V3_3),
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        fullRestrictionsHook = FullRestrictions(
            create3(
                createSalt("fullRestrictionsHook", V3_3),
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        freelyTransferableHook = FreelyTransferable(
            create3(
                createSalt("freelyTransferableHook", V3_3),
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        redemptionRestrictionsHook = RedemptionRestrictions(
            create3(
                createSalt("redemptionRestrictionsHook", V3_3),
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        queueManager = QueueManager(
            create3(
                createSalt("queueManager", V3_3),
                abi.encodePacked(type(QueueManager).creationCode, abi.encode(envoy, spoke))
            )
        );

        accountingToken = AccountingToken(
            create3(
                createSalt("accountingToken", V3_3),
                abi.encodePacked(type(AccountingToken).creationCode, abi.encode(envoy))
            )
        );

        // Timelock is immutable and matches the protocol delay. Per-pool stewards and MultiAdapter manager
        // registration are operational (governance) steps, so no deploy-time wiring is needed.
        adapterFailover = AdapterFailover(
            create3(
                createSalt("adapterFailover", V3_3),
                abi.encodePacked(type(AdapterFailover).creationCode, abi.encode(envoy, multiAdapter, uint64(DELAY)))
            )
        );

        scriptHelpers = ScriptHelpers(
            create3(createSalt("scriptHelpers", V3_2), abi.encodePacked(type(ScriptHelpers).creationCode))
        );

        onchainPMFactory = IOnchainPMFactory(
            create3(
                createSalt("onchainPMFactory", V3_3),
                abi.encodePacked(
                    vm.getCode("out-ir/OnchainPM.sol/OnchainPMFactory.json"),
                    abi.encode(contractUpdater, spoke, gateway)
                )
            )
        );

        flashLoanHelper = FlashLoanHelper(
            create3(
                createSalt("flashLoanHelper", V3_2),
                abi.encodePacked(type(FlashLoanHelper).creationCode, abi.encode(onchainPMFactory))
            )
        );

        onOffRampFactory = OnOffRampFactory(
            create3(
                createSalt("onOffRampFactory", V3_3),
                abi.encodePacked(type(OnOffRampFactory).creationCode, abi.encode(envoy, spoke, accountingToken))
            )
        );

        approvalGuard = ApprovalGuard(
            create3(createSalt("approvalGuard", V3_2), abi.encodePacked(type(ApprovalGuard).creationCode))
        );

        circuitBreakerGuard = CircuitBreakerGuard(
            create3(createSalt("circuitBreakerGuard", V3_3), abi.encodePacked(type(CircuitBreakerGuard).creationCode))
        );

        slippageGuard = SlippageGuard(
            create3(
                createSalt("slippageGuard", V3_3),
                abi.encodePacked(type(SlippageGuard).creationCode, abi.encode(spoke, envoy, onchainPMFactory))
            )
        );

        batchRequestManager = BatchRequestManager(
            create3(
                createSalt("batchRequestManager", V3_3),
                abi.encodePacked(
                    type(BatchRequestManager).creationCode, abi.encode(hubRegistry, gateway, address(envoy), batcher)
                )
            )
        );

        identityValuation = IdentityValuation(
            create3(
                createSalt("identityValuation", V3_1),
                abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        oracleValuation = OracleValuation(
            create3(
                createSalt("oracleValuation", V3_3),
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hub, hubRegistry, envoy))
            )
        );

        navManager = NAVManager(
            create3(
                createSalt("navManager", V3_3), abi.encodePacked(type(NAVManager).creationCode, abi.encode(hub, envoy))
            )
        );

        simplePriceManager = SimplePriceManager(
            create3(
                createSalt("simplePriceManager", V3_3),
                abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(navManager)))
            )
        );

        bridgeCircuitBreaker = BridgeCircuitBreaker(
            create3(
                createSalt("bridgeCircuitBreaker", V3_3),
                abi.encodePacked(
                    type(BridgeCircuitBreaker).creationCode,
                    abi.encode(address(envoy), address(circuitBreakerGuard), batcher)
                )
            )
        );

        tokenBridge = TokenBridge(
            create3(
                createSalt("tokenBridge", V3_3),
                abi.encodePacked(
                    type(TokenBridge).creationCode, abi.encode(spoke, gateway, centrifugeId_, address(envoy), batcher)
                )
            )
        );
    }

    function _deployAdapters(address batcher, AdaptersInput memory input) internal {
        if (input.layerZero.shouldDeploy) {
            require(input.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(input.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(input.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");
            require(
                input.layerZero.configParams.length == 0
                    || input.layerZero.configParams.length == input.connections.length,
                "configParams must mimics connections"
            );

            layerZeroAdapter = LayerZeroAdapter(
                create3(
                    createSalt("layerZeroAdapter", V3_3),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        // Set delegate to adapterBatcher initially, to be able to set ULN config
                        abi.encode(multiAdapter, input.layerZero.endpoint, batcher, batcher)
                    )
                )
            );
        }

        if (input.axelar.shouldDeploy) {
            require(input.axelar.gateway != address(0), "Axelar gateway address cannot be zero");
            require(input.axelar.gasService != address(0), "Axelar gas service address cannot be zero");
            require(input.axelar.gateway.code.length > 0, "Axelar gateway must be a deployed contract");
            require(input.axelar.gasService.code.length > 0, "Axelar gas service must be a deployed contract");

            axelarAdapter = AxelarAdapter(
                create3(
                    createSalt("axelarAdapter", V3_3),
                    abi.encodePacked(
                        type(AxelarAdapter).creationCode,
                        abi.encode(multiAdapter, input.axelar.gateway, input.axelar.gasService, batcher)
                    )
                )
            );
        }

        if (input.chainlink.shouldDeploy) {
            require(input.chainlink.ccipRouter != address(0), "Chainlink ccipRouter address cannot be zero");
            require(input.chainlink.ccipRouter.code.length > 0, "Chainlink ccipRouter must be a deployed contract");

            chainlinkAdapter = ChainlinkAdapter(
                create3(
                    createSalt("chainlinkAdapter", V3_3),
                    abi.encodePacked(
                        type(ChainlinkAdapter).creationCode,
                        abi.encode(multiAdapter, input.chainlink.ccipRouter, batcher)
                    )
                )
            );
        }

        if (input.hyperlane.shouldDeploy) {
            require(input.hyperlane.mailbox != address(0), "Hyperlane mailbox address cannot be zero");
            require(input.hyperlane.mailbox.code.length > 0, "Hyperlane mailbox must be a deployed contract");

            hyperlaneAdapter = HyperlaneAdapter(
                create3(
                    createSalt("hyperlaneAdapter", V3_3),
                    abi.encodePacked(
                        type(HyperlaneAdapter).creationCode, abi.encode(multiAdapter, input.hyperlane.mailbox, batcher)
                    )
                )
            );
        }
    }

    function coreReport() public view returns (CoreReport memory) {
        return CoreReport(
            gateway,
            multiAdapter,
            messageProcessor,
            messageDispatcher,
            poolEscrowFactory,
            spoke,
            snapshotQueue,
            shareTokenRegistrar,
            contractUpdater,
            spokeHandler,
            spokeRegistry,
            contractUpdaterForwarder,
            envoy,
            hubRegistry,
            accounting,
            holdings,
            shareClassManager,
            hubHandler,
            hub,
            root,
            protocolGuardian,
            opsGuardian,
            gasService
        );
    }

    function nonCoreReport() public view returns (NonCoreReport memory) {
        return NonCoreReport(
            coreReport(),
            subsidyManager,
            refundEscrowFactory,
            asyncVaultFactory,
            asyncRequestManager,
            syncDepositVaultFactory,
            syncManager,
            vaultRouter,
            freezeOnlyHook,
            fullRestrictionsHook,
            freelyTransferableHook,
            redemptionRestrictionsHook,
            queueManager,
            onOffRampFactory,
            batchRequestManager,
            identityValuation,
            oracleValuation,
            navManager,
            simplePriceManager,
            tokenBridge,
            bridgeCircuitBreaker
        );
    }

    function adaptersReport() public view returns (AdaptersReport memory) {
        return AdaptersReport(coreReport(), layerZeroAdapter, axelarAdapter, chainlinkAdapter, hyperlaneAdapter);
    }
}

function noAdaptersInput() pure returns (AdaptersInput memory) {
    return AdaptersInput({
        axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
        layerZero: LayerZeroInput({
            shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
        }),
        chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
        hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
        connections: new AdapterConnections[](0)
    });
}

function defaultTxLimits() pure returns (uint8[32] memory) {}
