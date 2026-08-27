// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GatedDeployer, DeployPhase} from "./GatedDeployer.s.sol";

import {Hub} from "../../src/core/hub/Hub.sol";
import {Envoy} from "../../src/core/utils/Envoy.sol";
import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {Holdings} from "../../src/core/hub/Holdings.sol";
import {Accounting} from "../../src/core/hub/Accounting.sol";
import {Gateway} from "../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {SpokeHandler} from "../../src/core/spoke/SpokeHandler.sol";
import {SnapshotQueue} from "../../src/core/spoke/SnapshotQueue.sol";
import {SpokeRegistry} from "../../src/core/spoke/SpokeRegistry.sol";
import {MultiAdapter} from "../../src/core/messaging/MultiAdapter.sol";
import {ShareClassManager} from "../../src/core/hub/ShareClassManager.sol";
import {MessageProcessor} from "../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../../src/admin/Root.sol";
import {GasService} from "../../src/admin/GasService.sol";
import {ISafe} from "../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../../src/token/hooks/FreezeOnly.sol";
import {NAVManager} from "../../src/hooks/accounting/NAVManager.sol";
import {FullRestrictions} from "../../src/token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../src/token/hooks/FreelyTransferable.sol";
import {BridgeCircuitBreaker} from "../../src/hooks/bridge/BridgeCircuitBreaker.sol";
import {SimplePriceManager} from "../../src/hooks/accounting/SimplePriceManager.sol";
import {RedemptionRestrictions} from "../../src/token/hooks/RedemptionRestrictions.sol";

import {QueueManager} from "../../src/managers/spoke/QueueManager.sol";
import {ShareManager} from "../../src/managers/spoke/ShareManager.sol";
import {OnOffRampFactory} from "../../src/managers/spoke/OnOffRamp.sol";
import {ScriptHelpers} from "../../src/managers/spoke/ScriptHelpers.sol";
import {AccountingToken} from "../../src/managers/spoke/AccountingToken.sol";
import {FlashLoanHelper} from "../../src/managers/spoke/FlashLoanHelper.sol";
import {AdapterFailover} from "../../src/managers/adapters/AdapterFailover.sol";
import {ApprovalGuard} from "../../src/managers/spoke/guards/ApprovalGuard.sol";
import {SlippageGuard} from "../../src/managers/spoke/guards/SlippageGuard.sol";
import {CircuitBreakerGuard} from "../../src/managers/spoke/guards/CircuitBreakerGuard.sol";
import {IOnchainPMFactory} from "../../src/managers/spoke/interfaces/IOnchainPMFactory.sol";

import {OracleValuation} from "../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../../src/vaults/factories/SyncDepositVaultFactory.sol";

import {VmSafe} from "forge-std/Vm.sol";

import {RootFixes} from "../../src/deployment/RootFixes.sol";
import {TokenBridge} from "../../src/bridge/TokenBridge.sol";
import {SubsidyManager} from "../../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../../src/adapters/AxelarAdapter.sol";
import {ChainlinkAdapter} from "../../src/adapters/ChainlinkAdapter.sol";
import {HyperlaneAdapter} from "../../src/adapters/HyperlaneAdapter.sol";
import {LayerZeroAdapter} from "../../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../../src/utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../../src/token/ShareTokenRegistrar.sol";
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
} from "../../src/deployment/ActionBatchers.sol";

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
    string deploymentId;
    uint8[32] txLimits;
    ISafe protocolSafe;
    ISafe opsSafe;
    // Both reach init code, so both have to come out the same in either gate phase. `delay` is what a fresh
    // Root is deployed with, and is ignored where one is kept
    address root;
    uint256 delay;
    AdaptersInput adapters;
}

contract FullDeployer is GatedDeployer, Constants {
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
    SpokeRegistry public spokeRegistry;
    SpokeHandler public spokeHandler;
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
    ShareManager public shareManager;
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

    RootFixes public rootFixes;

    CoreActionBatcher public coreBatcher;
    NonCoreActionBatcher public nonCoreBatcher;
    AdapterActionBatcher public adapterBatcher;

    /// @dev Runs both phases back to back, in one process. For tests only: a real deployment gives each phase
    ///      its own run, which is what proves the deploy phase rebuilds exactly what the commit phase committed.
    ///      FullDeploymentPhasedTest is what covers the phases apart.
    function deployFullBothPhases(DeployerInput memory input, address namespace_, address[] memory executors_) public {
        deployFull(input, DeployPhase.Commit, namespace_, executors_);
        deployFull(input, DeployPhase.Deploy, namespace_, executors_);
    }

    /// @dev Deploys every contract through a DeployGate, so that the admin signs a single transaction whatever
    ///      the number of contracts. NOTE: this changes every deployed address, since a CREATE3 address
    ///      derives from the CreateX caller.
    ///      The phase acts as `msg.sender` — committing, the namespace or a delegate of it, a key or a Safe;
    ///      deploying, an executor — so who that is belongs to the caller: see `GatedDeployer._initGated`.
    function deployFull(DeployerInput memory input, DeployPhase phase, address namespace_, address[] memory executors_)
        public
    {
        _initGated(input.deploymentId, phase, namespace_, executors_);

        // Committing deploys the whole protocol locally, at the addresses it will really occupy, since only
        // running the init code reveals the runtime code to commit to, and constructors that wire their
        // dependencies need to find them. That is then rolled back, to leave the addresses free for the
        // executor: the commitment is carried across in memory, which a rollback does not touch.
        //
        // Everything the walk put in storage does go, this script's own included, which is what keeps the
        // addresses it registered out of the deployment manifest: only the deploy phase reports any.
        if (phase == DeployPhase.Commit) {
            bool bracketed = vm.isContext(VmSafe.ForgeContext.ScriptGroup) && !proposing;
            if (bracketed) vm.stopBroadcast();

            uint256 snapshot = vm.snapshotState();

            // A no-op except when proposing, the one run that reaches here without a gate: the walk needs
            // one to ask for addresses, and bringing it up inside the rollback is what keeps the chain
            // readable for the proposal built after it
            setUpDeployGate();
            _deployProtocol(input);
            (bytes32[] memory salts, bytes32[] memory initCodeHashes) = _queuedCommitment();

            // Carried across the rollback in memory, as the commitment is, so that a validating run can still
            // name the one address it leaves work behind at
            address rootFixes_ = address(rootFixes);
            vm.revertToState(snapshot);
            rootFixes = RootFixes(rootFixes_);

            if (bracketed) vm.startBroadcast();

            _commit(salts, initCodeHashes);
        } else {
            _deployProtocol(input);

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
    }

    /// @dev One walk of the whole protocol. Deploys through the DeployGate, or locally when probing.
    function _deployProtocol(DeployerInput memory input) internal {
        address coreBatcherAddr = gatedAddress("coreBatcher", V_LATEST);
        address nonCoreBatcherAddr = gatedAddress("nonCoreBatcher", V_LATEST);
        address adapterBatcherAddr = gatedAddress("adapterBatcher", V_LATEST);

        _deployCore(coreBatcherAddr, input);
        coreBatcher = CoreActionBatcher(
            submitUnreported(
                "coreBatcher",
                V_LATEST,
                abi.encodePacked(
                    type(CoreActionBatcher).creationCode,
                    abi.encode(
                        coreReport(),
                        input.protocolSafe,
                        input.opsSafe,
                        adapterBatcherAddr,
                        nonCoreBatcherAddr,
                        input.root == address(0)
                    )
                )
            )
        );

        _deployNonCore(nonCoreBatcherAddr, input);
        nonCoreBatcher = NonCoreActionBatcher(
            submitUnreported(
                "nonCoreBatcher",
                V_LATEST,
                abi.encodePacked(
                    type(NonCoreActionBatcher).creationCode, abi.encode(nonCoreReport(), input.root == address(0))
                )
            )
        );

        _deployAdapters(adapterBatcherAddr, input.adapters);
        adapterBatcher = AdapterActionBatcher(
            submitUnreported(
                "adapterBatcher",
                V_LATEST,
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

        if (input.root != address(0)) {
            rootFixes = RootFixes(
                submitUnreported(
                    "rootFixes", V_LATEST, abi.encodePacked(type(RootFixes).creationCode, abi.encode(nonCoreReport()))
                )
            );
        }
    }

    function _deployCore(address batcher, DeployerInput memory input) internal {
        address tokenBridgeAddr = gatedAddress("tokenBridge", V3_3);

        // Admin
        root = input.root != address(0)
            ? _existingRoot(input.root)
            : Root(submit("root", V3_3, abi.encodePacked(type(Root).creationCode, abi.encode(input.delay, batcher))));

        gasService = GasService(
            submit(
                "gasService",
                V3_3,
                abi.encodePacked(type(GasService).creationCode, abi.encode(input.txLimits, input.centrifugeId))
            )
        );

        // Messaging
        gateway = Gateway(
            submit(
                "gateway",
                V3_3,
                abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, root, batcher))
            )
        );

        multiAdapter = MultiAdapter(
            submit(
                "multiAdapter",
                V3_3,
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, batcher))
            )
        );

        envoy = Envoy(submit("envoy", V3_3, abi.encodePacked(type(Envoy).creationCode, abi.encode(batcher))));

        messageProcessor = MessageProcessor(
            submit(
                "messageProcessor",
                V3_3,
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, batcher))
            )
        );

        messageDispatcher = MessageDispatcher(
            submit(
                "messageDispatcher",
                V3_3,
                abi.encodePacked(
                    type(MessageDispatcher).creationCode, abi.encode(input.centrifugeId, root, gateway, batcher)
                )
            )
        );

        // Spoke
        shareTokenRegistrar = ShareTokenRegistrar(
            submit(
                "shareTokenRegistrar",
                V3_3,
                abi.encodePacked(type(ShareTokenRegistrar).creationCode, abi.encode(root, batcher))
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            submit(
                "poolEscrowFactory",
                V3_3,
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(root, batcher))
            )
        );

        spokeRegistry = SpokeRegistry(
            submit("spokeRegistry", V3_3, abi.encodePacked(type(SpokeRegistry).creationCode, abi.encode(batcher)))
        );

        snapshotQueue = SnapshotQueue(
            submit("snapshotQueue", V3_3, abi.encodePacked(type(SnapshotQueue).creationCode, abi.encode(batcher)))
        );

        spoke = Spoke(
            submit(
                "spoke",
                V3_3,
                abi.encodePacked(
                    type(Spoke).creationCode,
                    abi.encode(gateway, snapshotQueue, spokeRegistry, poolEscrowFactory, batcher)
                )
            )
        );

        spokeHandler = SpokeHandler(
            submit(
                "spokeHandler",
                V3_3,
                abi.encodePacked(type(SpokeHandler).creationCode, abi.encode(spokeRegistry, poolEscrowFactory, batcher))
            )
        );

        // Hub
        hubRegistry = HubRegistry(
            submit("hubRegistry", V3_3, abi.encodePacked(type(HubRegistry).creationCode, abi.encode(batcher)))
        );

        accounting = Accounting(
            submit("accounting", V3_3, abi.encodePacked(type(Accounting).creationCode, abi.encode(batcher)))
        );

        holdings = Holdings(
            submit("holdings", V3_3, abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, batcher)))
        );

        shareClassManager = ShareClassManager(
            submit(
                "shareClassManager",
                V3_3,
                abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        hub = Hub(
            submit(
                "hub",
                V3_3,
                abi.encodePacked(
                    type(Hub).creationCode,
                    abi.encode(gateway, holdings, accounting, hubRegistry, multiAdapter, shareClassManager, batcher)
                )
            )
        );

        hubHandler = HubHandler(
            submit(
                "hubHandler",
                V3_3,
                abi.encodePacked(
                    type(HubHandler).creationCode, abi.encode(hub, holdings, hubRegistry, shareClassManager, batcher)
                )
            )
        );

        // Admin (depends on core contracts)
        protocolGuardian = ProtocolGuardian(
            submit(
                "protocolGuardian",
                V3_3,
                abi.encodePacked(
                    type(ProtocolGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, messageDispatcher, TokenBridge(tokenBridgeAddr))
                )
            )
        );

        opsGuardian = OpsGuardian(
            submit(
                "opsGuardian",
                V3_3,
                abi.encodePacked(
                    type(OpsGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), hub, TokenBridge(tokenBridgeAddr), multiAdapter)
                )
            )
        );
    }

    /// @dev Taken as it stands: its delay, wards and endorsements are whatever governance left them.
    ///      Registered anyway, so `REPLACE` keeps the entry rather than dropping it, and with no version, so
    ///      the registry keeps the version and block number already recorded against that address.
    function _existingRoot(address root_) internal returns (Root) {
        require(root_.code.length > 0, "The root passed in is not a deployed contract");

        register("root", root_, "");

        return Root(root_);
    }

    function _deployNonCore(address batcher, DeployerInput memory input) internal {
        refundEscrowFactory = RefundEscrowFactory(
            submit(
                "refundEscrowFactory",
                V3_3,
                abi.encodePacked(type(RefundEscrowFactory).creationCode, abi.encode(batcher))
            )
        );

        subsidyManager = SubsidyManager(
            submit(
                "subsidyManager",
                V3_3,
                abi.encodePacked(type(SubsidyManager).creationCode, abi.encode(refundEscrowFactory, batcher))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(submit(
                    "asyncRequestManager",
                    V3_3,
                    abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(subsidyManager, batcher))
                ))
        );

        syncManager = SyncManager(
            submit("syncManager", V3_3, abi.encodePacked(type(SyncManager).creationCode, abi.encode(batcher)))
        );

        vaultRouter = VaultRouter(
            submit(
                "vaultRouter",
                V3_3,
                abi.encodePacked(type(VaultRouter).creationCode, abi.encode(spoke, spokeRegistry, batcher))
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            submit(
                "asyncVaultFactory",
                V3_3,
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, batcher)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            submit(
                "syncDepositVaultFactory",
                V3_3,
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, batcher)
                )
            )
        );

        freezeOnlyHook = FreezeOnly(
            submit(
                "freezeOnlyHook",
                V3_3,
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory)
                    )
                )
            )
        );

        fullRestrictionsHook = FullRestrictions(
            submit(
                "fullRestrictionsHook",
                V3_3,
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory)
                    )
                )
            )
        );

        freelyTransferableHook = FreelyTransferable(
            submit(
                "freelyTransferableHook",
                V3_3,
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory)
                    )
                )
            )
        );

        redemptionRestrictionsHook = RedemptionRestrictions(
            submit(
                "redemptionRestrictionsHook",
                V3_3,
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(envoy),
                        address(spokeRegistry),
                        address(spoke),
                        address(spokeHandler),
                        batcher,
                        address(poolEscrowFactory)
                    )
                )
            )
        );

        queueManager = QueueManager(
            submit("queueManager", V3_3, abi.encodePacked(type(QueueManager).creationCode, abi.encode(envoy, spoke)))
        );

        accountingToken = AccountingToken(
            submit("accountingToken", V3_3, abi.encodePacked(type(AccountingToken).creationCode, abi.encode(envoy)))
        );

        // Timelock is immutable and matches the protocol delay, read off the Root in use rather than off the
        // input: a kept Root keeps whatever delay governance left it. Per-pool stewards and MultiAdapter
        // manager registration are operational (governance) steps, so no deploy-time wiring is needed.
        adapterFailover = AdapterFailover(
            submit(
                "adapterFailover",
                V3_3,
                abi.encodePacked(
                    type(AdapterFailover).creationCode, abi.encode(envoy, multiAdapter, uint64(root.delay()))
                )
            )
        );

        scriptHelpers = ScriptHelpers(submit("scriptHelpers", V3_3, abi.encodePacked(type(ScriptHelpers).creationCode)));

        onchainPMFactory = IOnchainPMFactory(
            submit(
                "onchainPMFactory",
                V3_3,
                abi.encodePacked(
                    vm.getCode("out-ir/OnchainPM.sol/OnchainPMFactory.json"), abi.encode(envoy, spoke, gateway)
                )
            )
        );

        flashLoanHelper = FlashLoanHelper(
            submit(
                "flashLoanHelper",
                V3_3,
                abi.encodePacked(type(FlashLoanHelper).creationCode, abi.encode(onchainPMFactory))
            )
        );

        onOffRampFactory = OnOffRampFactory(
            submit(
                "onOffRampFactory",
                V3_3,
                abi.encodePacked(type(OnOffRampFactory).creationCode, abi.encode(envoy, spoke, accountingToken))
            )
        );

        shareManager = ShareManager(
            submit(
                "shareManager",
                V3_3,
                abi.encodePacked(type(ShareManager).creationCode, abi.encode(envoy, spoke, spokeRegistry))
            )
        );

        approvalGuard = ApprovalGuard(submit("approvalGuard", V3_3, abi.encodePacked(type(ApprovalGuard).creationCode)));

        circuitBreakerGuard = CircuitBreakerGuard(
            submit("circuitBreakerGuard", V3_3, abi.encodePacked(type(CircuitBreakerGuard).creationCode))
        );

        slippageGuard = SlippageGuard(
            submit(
                "slippageGuard",
                V3_3,
                abi.encodePacked(type(SlippageGuard).creationCode, abi.encode(spoke, envoy, onchainPMFactory))
            )
        );

        batchRequestManager = BatchRequestManager(
            submit(
                "batchRequestManager",
                V3_3,
                abi.encodePacked(
                    type(BatchRequestManager).creationCode, abi.encode(hubRegistry, gateway, address(envoy), batcher)
                )
            )
        );

        identityValuation = IdentityValuation(
            submit(
                "identityValuation",
                V3_3,
                abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        oracleValuation = OracleValuation(
            submit(
                "oracleValuation",
                V3_3,
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hub, hubRegistry, envoy))
            )
        );

        navManager = NAVManager(
            submit("navManager", V3_3, abi.encodePacked(type(NAVManager).creationCode, abi.encode(hub, envoy)))
        );

        simplePriceManager = SimplePriceManager(
            submit(
                "simplePriceManager",
                V3_3,
                abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(navManager)))
            )
        );

        bridgeCircuitBreaker = BridgeCircuitBreaker(
            submit(
                "bridgeCircuitBreaker",
                V3_3,
                abi.encodePacked(
                    type(BridgeCircuitBreaker).creationCode,
                    abi.encode(address(envoy), address(circuitBreakerGuard), batcher)
                )
            )
        );

        tokenBridge = TokenBridge(
            submit(
                "tokenBridge",
                V3_3,
                abi.encodePacked(
                    type(TokenBridge).creationCode,
                    abi.encode(spoke, gateway, input.centrifugeId, address(envoy), batcher)
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
                submit(
                    "layerZeroAdapter",
                    V3_3,
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
                submit(
                    "axelarAdapter",
                    V3_3,
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
                submit(
                    "chainlinkAdapter",
                    V3_3,
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
                submit(
                    "hyperlaneAdapter",
                    V3_3,
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
            spokeHandler,
            spokeRegistry,
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
            shareManager,
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
