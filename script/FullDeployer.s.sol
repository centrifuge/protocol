// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";

import {Hub} from "../src/core/hub/Hub.sol";
import {Spoke} from "../src/core/spoke/Spoke.sol";
import {Holdings} from "../src/core/hub/Holdings.sol";
import {Accounting} from "../src/core/hub/Accounting.sol";
import {Gateway} from "../src/core/messaging/Gateway.sol";
import {HubHandler} from "../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../src/core/hub/HubRegistry.sol";
import {BalanceSheet} from "../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../src/core/messaging/GasService.sol";
import {VaultRegistry} from "../src/core/spoke/VaultRegistry.sol";
import {MultiAdapter} from "../src/core/messaging/MultiAdapter.sol";
import {ContractUpdater} from "../src/core/utils/ContractUpdater.sol";
import {ShareClassManager} from "../src/core/hub/ShareClassManager.sol";
import {TokenFactory} from "../src/core/spoke/factories/TokenFactory.sol";
import {MessageProcessor} from "../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../src/core/messaging/MessageDispatcher.sol";
import {PoolEscrowFactory} from "../src/core/spoke/factories/PoolEscrowFactory.sol";

import {Root} from "../src/admin/Root.sol";
import {ISafe} from "../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../src/admin/OpsGuardian.sol";
import {TokenRecoverer} from "../src/admin/TokenRecoverer.sol";
import {ProtocolGuardian} from "../src/admin/ProtocolGuardian.sol";

import {FreezeOnly} from "../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../src/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../src/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../src/hooks/RedemptionRestrictions.sol";

import {NAVManager} from "../src/managers/hub/NAVManager.sol";
import {QueueManager} from "../src/managers/spoke/QueueManager.sol";
import {VaultDecoder} from "../src/managers/spoke/decoders/VaultDecoder.sol";
import {SimplePriceManager} from "../src/managers/hub/SimplePriceManager.sol";
import {CircleDecoder} from "../src/managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../src/managers/spoke/MerkleProofManager.sol";

import {OracleValuation} from "../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../src/vaults/SyncManager.sol";
import {VaultRouter} from "../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../src/vaults/BatchRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import {SubsidyManager} from "../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../src/utils/RefundEscrowFactory.sol";
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

struct WormholeInput {
    bool shouldDeploy;
    address relayer;
}

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

struct AdaptersInput {
    LayerZeroInput layerZero;
    WormholeInput wormhole;
    AxelarInput axelar;
    ChainlinkInput chainlink;
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
    TokenRecoverer public tokenRecoverer;
    ProtocolGuardian public protocolGuardian;
    OpsGuardian public opsGuardian;

    Gateway public gateway;
    MultiAdapter public multiAdapter;

    GasService public gasService;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    Spoke public spoke;
    BalanceSheet public balanceSheet;
    TokenFactory public tokenFactory;
    ContractUpdater public contractUpdater;
    VaultRegistry public vaultRegistry;
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

    FreezeOnly public freezeOnlyHook;
    FullRestrictions public fullRestrictionsHook;
    FreelyTransferable public freelyTransferableHook;
    RedemptionRestrictions public redemptionRestrictionsHook;

    QueueManager public queueManager;
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    BatchRequestManager public batchRequestManager;

    IdentityValuation public identityValuation;
    OracleValuation public oracleValuation;

    NAVManager public navManager;
    SimplePriceManager public simplePriceManager;

    ChainlinkAdapter chainlinkAdapter;
    AxelarAdapter axelarAdapter;
    WormholeAdapter wormholeAdapter;
    LayerZeroAdapter layerZeroAdapter;

    CoreActionBatcher public coreBatcher;
    NonCoreActionBatcher public nonCoreBatcher;
    AdapterActionBatcher public adapterBatcher;

    function deployFull(DeployerInput memory input, address deployer_) public {
        _init(input.suffix, deployer_);

        address coreBatcherAddr = previewCreate3Address("coreBatcher", "v3.1");
        address nonCoreBatcherAddr = previewCreate3Address("nonCoreBatcher", "v3.1");
        address adapterBatcherAddr = previewCreate3Address("adapterBatcher", "v3.1");

        _deployCore(coreBatcherAddr, input);
        coreBatcher = CoreActionBatcher(
            create3(
                createSalt("coreBatcher", "v3.1"),
                abi.encodePacked(
                    type(CoreActionBatcher).creationCode,
                    abi.encode(coreReport(), input.protocolSafe, input.opsSafe, adapterBatcherAddr, nonCoreBatcherAddr)
                )
            )
        );

        _deployNonCore(nonCoreBatcherAddr);
        nonCoreBatcher = NonCoreActionBatcher(
            create3(
                createSalt("nonCoreBatcher", "v3.1"),
                abi.encodePacked(type(NonCoreActionBatcher).creationCode, abi.encode(nonCoreReport()))
            )
        );

        _deployAdapters(adapterBatcherAddr, input.adapters);
        adapterBatcher = AdapterActionBatcher(
            create3(
                createSalt("adapterBatcher", "v3.1"),
                abi.encodePacked(
                    type(AdapterActionBatcher).creationCode,
                    abi.encode(
                        adaptersReport(),
                        input.protocolSafe,
                        input.adapters.connections,
                        input.adapters.layerZero.configParams,
                        input.adapters.layerZero.delegate,
                        vm.toString(address(axelarAdapter))
                    )
                )
            )
        );
    }

    function _deployCore(address batcher, DeployerInput memory input) internal {
        // Admin
        root = Root(
            create3(createSalt("root", "v3.1"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, batcher)))
        );

        // Core
        gateway = Gateway(
            create3(
                createSalt("gateway", "v3.1"),
                abi.encodePacked(type(Gateway).creationCode, abi.encode(input.centrifugeId, root, batcher))
            )
        );

        multiAdapter = MultiAdapter(
            create3(
                createSalt("multiAdapter", "v3.1"),
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, batcher))
            )
        );

        contractUpdater = ContractUpdater(
            create3(
                createSalt("contractUpdater", "v3.1"),
                abi.encodePacked(type(ContractUpdater).creationCode, abi.encode(batcher))
            )
        );

        // Messaging
        gasService = GasService(
            create3(
                createSalt("gasService", "v3.1"),
                abi.encodePacked(type(GasService).creationCode, abi.encode(input.txLimits))
            )
        );

        messageProcessor = MessageProcessor(
            create3(
                createSalt("messageProcessor", "v3.1"),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, batcher))
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                createSalt("messageDispatcher", "v3.1"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode, abi.encode(input.centrifugeId, root, gateway, batcher)
                )
            )
        );

        // Spoke
        tokenFactory = TokenFactory(
            create3(
                createSalt("tokenFactory", "v3.1"),
                abi.encodePacked(type(TokenFactory).creationCode, abi.encode(root, batcher))
            )
        );

        spoke = Spoke(
            create3(
                createSalt("spoke", "v3.1"),
                abi.encodePacked(type(Spoke).creationCode, abi.encode(tokenFactory, batcher))
            )
        );

        balanceSheet = BalanceSheet(
            create3(
                createSalt("balanceSheet", "v3.1"),
                abi.encodePacked(type(BalanceSheet).creationCode, abi.encode(root, batcher))
            )
        );

        vaultRegistry = VaultRegistry(
            create3(
                createSalt("vaultRegistry", "v3.1"),
                abi.encodePacked(type(VaultRegistry).creationCode, abi.encode(batcher))
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3(
                createSalt("poolEscrowFactory", "v3.1"),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(root, batcher))
            )
        );

        // Hub
        hubRegistry = HubRegistry(
            create3(
                createSalt("hubRegistry", "v3.1"), abi.encodePacked(type(HubRegistry).creationCode, abi.encode(batcher))
            )
        );

        accounting = Accounting(
            create3(
                createSalt("accounting", "v3.1"), abi.encodePacked(type(Accounting).creationCode, abi.encode(batcher))
            )
        );

        holdings = Holdings(
            create3(
                createSalt("holdings", "v3.1"),
                abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        shareClassManager = ShareClassManager(
            create3(
                createSalt("shareClassManager", "v3.1"),
                abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        hub = Hub(
            create3(
                createSalt("hub", "v3.1"),
                abi.encodePacked(
                    type(Hub).creationCode,
                    abi.encode(gateway, holdings, accounting, hubRegistry, multiAdapter, shareClassManager, batcher)
                )
            )
        );

        hubHandler = HubHandler(
            create3(
                createSalt("hubHandler", "v3.1"),
                abi.encodePacked(
                    type(HubHandler).creationCode, abi.encode(hub, holdings, hubRegistry, shareClassManager, batcher)
                )
            )
        );

        // Admin (depends on core contracts)
        tokenRecoverer = TokenRecoverer(
            create3(
                createSalt("tokenRecoverer", "v3.1"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, batcher))
            )
        );

        protocolGuardian = ProtocolGuardian(
            create3(
                createSalt("protocolGuardian", "v3.1"),
                abi.encodePacked(
                    type(ProtocolGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, gateway, messageDispatcher)
                )
            )
        );

        opsGuardian = OpsGuardian(
            create3(
                createSalt("opsGuardian", "v3.1"),
                abi.encodePacked(type(OpsGuardian).creationCode, abi.encode(ISafe(address(batcher)), hub, multiAdapter))
            )
        );
    }

    function _deployNonCore(address batcher) internal {
        refundEscrowFactory = RefundEscrowFactory(
            create3(
                createSalt("refundEscrowFactory", "v3.1"),
                abi.encodePacked(type(RefundEscrowFactory).creationCode, abi.encode(batcher))
            )
        );

        subsidyManager = SubsidyManager(
            create3(
                createSalt("subsidyManager", "v3.1"),
                abi.encodePacked(type(SubsidyManager).creationCode, abi.encode(refundEscrowFactory, batcher))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(create3(
                    createSalt("asyncRequestManager", "v3.1"),
                    abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(subsidyManager, batcher))
                ))
        );

        syncManager = SyncManager(
            create3(
                createSalt("syncManager", "v3.1"), abi.encodePacked(type(SyncManager).creationCode, abi.encode(batcher))
            )
        );

        vaultRouter = VaultRouter(
            create3(
                createSalt("vaultRouter", "v3.1"),
                abi.encodePacked(type(VaultRouter).creationCode, abi.encode(gateway, spoke, vaultRegistry, batcher))
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3(
                createSalt("asyncVaultFactory", "v3.1"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, batcher)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                createSalt("syncDepositVaultFactory", "v3.1"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, batcher)
                )
            )
        );

        freezeOnlyHook = FreezeOnly(
            create3(
                createSalt("freezeOnlyHook", "v3.1"),
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        fullRestrictionsHook = FullRestrictions(
            create3(
                createSalt("fullRestrictionsHook", "v3.1"),
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        freelyTransferableHook = FreelyTransferable(
            create3(
                createSalt("freelyTransferableHook", "v3.1"),
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        redemptionRestrictionsHook = RedemptionRestrictions(
            create3(
                createSalt("redemptionRestrictionsHook", "v3.1"),
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(spoke),
                        batcher,
                        address(poolEscrowFactory),
                        address(0)
                    )
                )
            )
        );

        queueManager = QueueManager(
            create3(
                createSalt("queueManager", "v3.1"),
                abi.encodePacked(
                    type(QueueManager).creationCode, abi.encode(contractUpdater, balanceSheet, address(batcher))
                )
            )
        );

        onOfframpManagerFactory = OnOfframpManagerFactory(
            create3(
                createSalt("onOfframpManagerFactory", "v3.1"),
                abi.encodePacked(type(OnOfframpManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet))
            )
        );

        merkleProofManagerFactory = MerkleProofManagerFactory(
            create3(
                createSalt("merkleProofManagerFactory", "v3.1"),
                abi.encodePacked(
                    type(MerkleProofManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet)
                )
            )
        );

        vaultDecoder = VaultDecoder(
            create3(createSalt("vaultDecoder", "v3.1"), abi.encodePacked(type(VaultDecoder).creationCode))
        );

        circleDecoder = CircleDecoder(
            create3(createSalt("circleDecoder", "v3.1"), abi.encodePacked(type(CircleDecoder).creationCode))
        );

        batchRequestManager = BatchRequestManager(
            create3(
                createSalt("batchRequestManager", "v3.1"),
                abi.encodePacked(type(BatchRequestManager).creationCode, abi.encode(hubRegistry, gateway, batcher))
            )
        );

        identityValuation = IdentityValuation(
            create3(
                createSalt("identityValuation", "v3.1"),
                abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        oracleValuation = OracleValuation(
            create3(
                createSalt("oracleValuation", "v3.1"),
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hub, hubRegistry))
            )
        );

        navManager = NAVManager(
            create3(createSalt("navManager", "v3.1"), abi.encodePacked(type(NAVManager).creationCode, abi.encode(hub)))
        );

        simplePriceManager = SimplePriceManager(
            create3(
                createSalt("simplePriceManager", "v3.1"),
                abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(navManager)))
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
                    createSalt("layerZeroAdapter", "v3.1"),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        // Set delegate to adapterBatcher initially, to be able to set ULN config
                        abi.encode(multiAdapter, input.layerZero.endpoint, batcher, batcher)
                    )
                )
            );
        }

        if (input.wormhole.shouldDeploy) {
            require(input.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(input.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");

            wormholeAdapter = WormholeAdapter(
                create3(
                    createSalt("wormholeAdapter", "v3.1"),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode, abi.encode(multiAdapter, input.wormhole.relayer, batcher)
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
                    createSalt("axelarAdapter", "v3.1"),
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
                    createSalt("chainlinkAdapter", "v3.1"),
                    abi.encodePacked(
                        type(ChainlinkAdapter).creationCode,
                        abi.encode(multiAdapter, input.chainlink.ccipRouter, batcher)
                    )
                )
            );
        }
    }

    function coreReport() public view returns (CoreReport memory) {
        return CoreReport(
            gateway,
            multiAdapter,
            gasService,
            messageProcessor,
            messageDispatcher,
            poolEscrowFactory,
            spoke,
            balanceSheet,
            tokenFactory,
            contractUpdater,
            vaultRegistry,
            hubRegistry,
            accounting,
            holdings,
            shareClassManager,
            hubHandler,
            hub,
            root,
            tokenRecoverer,
            protocolGuardian,
            opsGuardian
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
            onOfframpManagerFactory,
            merkleProofManagerFactory,
            vaultDecoder,
            circleDecoder,
            batchRequestManager,
            identityValuation,
            oracleValuation,
            navManager,
            simplePriceManager
        );
    }

    function adaptersReport() public view returns (AdaptersReport memory) {
        return AdaptersReport(coreReport(), layerZeroAdapter, wormholeAdapter, axelarAdapter, chainlinkAdapter);
    }
}

function noAdaptersInput() pure returns (AdaptersInput memory) {
    return AdaptersInput({
        wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
        axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
        layerZero: LayerZeroInput({
            shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
        }),
        chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
        connections: new AdapterConnections[](0)
    });
}

function defaultTxLimits() pure returns (uint8[32] memory) {}
