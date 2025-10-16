// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreInput, CoreReport, CoreDeployer, CoreActionBatcher} from "./CoreDeployer.s.sol";

import {Escrow} from "../src/misc/Escrow.sol";

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
import {RefundEscrowFactory} from "../src/vaults/factories/RefundEscrowFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import "forge-std/Script.sol";

import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";

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
}

struct AdaptersInput {
    WormholeInput wormhole;
    AxelarInput axelar;
    LayerZeroInput layerZero;
}

struct FullInput {
    ISafe adminSafe;
    ISafe opsSafe;
    CoreInput core;
    AdaptersInput adapters;
}

struct FullReport {
    CoreReport core;
    Root root;
    TokenRecoverer tokenRecoverer;
    ProtocolGuardian protocolGuardian;
    OpsGuardian opsGuardian;
    Escrow routerEscrow;
    Escrow globalEscrow;
    RefundEscrowFactory refundEscrowFactory;
    AsyncVaultFactory asyncVaultFactory;
    AsyncRequestManager asyncRequestManager;
    SyncDepositVaultFactory syncDepositVaultFactory;
    SyncManager syncManager;
    VaultRouter vaultRouter;
    FreezeOnly freezeOnlyHook;
    FullRestrictions fullRestrictionsHook;
    FreelyTransferable freelyTransferableHook;
    RedemptionRestrictions redemptionRestrictionsHook;
    QueueManager queueManager;
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
    BatchRequestManager batchRequestManager;
    IdentityValuation identityValuation;
    OracleValuation oracleValuation;
    NAVManager navManager;
    SimplePriceManager simplePriceManager;
    WormholeAdapter wormholeAdapter;
    AxelarAdapter axelarAdapter;
    LayerZeroAdapter layerZeroAdapter;
}

contract FullActionBatcher is CoreActionBatcher {
    function engageFull(FullReport memory report, ISafe adminSafe, ISafe opsSafe) public onlyDeployer {
        // Rely Root
        report.tokenRecoverer.rely(address(report.root));

        report.routerEscrow.rely(address(report.root));
        report.globalEscrow.rely(address(report.root));
        report.refundEscrowFactory.rely(address(report.root));
        report.asyncVaultFactory.rely(address(report.root));
        report.asyncRequestManager.rely(address(report.root));
        report.syncDepositVaultFactory.rely(address(report.root));
        report.syncManager.rely(address(report.root));
        report.vaultRouter.rely(address(report.root));

        report.freezeOnlyHook.rely(address(report.root));
        report.fullRestrictionsHook.rely(address(report.root));
        report.freelyTransferableHook.rely(address(report.root));
        report.redemptionRestrictionsHook.rely(address(report.root));

        report.batchRequestManager.rely(address(report.root));

        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.rely(address(report.root));
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.rely(address(report.root));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.rely(address(report.root));

        // Rely spoke
        report.asyncRequestManager.rely(address(report.core.spoke));
        report.freezeOnlyHook.rely(address(report.core.spoke));
        report.fullRestrictionsHook.rely(address(report.core.spoke));
        report.freelyTransferableHook.rely(address(report.core.spoke));
        report.redemptionRestrictionsHook.rely(address(report.core.spoke));

        // Rely vaultRegistry
        report.asyncVaultFactory.rely(address(report.core.vaultRegistry));
        report.syncDepositVaultFactory.rely(address(report.core.vaultRegistry));

        // Rely contractUpdater
        report.syncManager.rely(address(report.core.contractUpdater));
        report.asyncRequestManager.rely(address(report.core.contractUpdater));

        // Rely protocolGuardian
        report.core.gateway.rely(address(report.protocolGuardian));
        report.core.multiAdapter.rely(address(report.protocolGuardian));
        report.core.messageDispatcher.rely(address(report.protocolGuardian));
        report.root.rely(address(report.protocolGuardian));
        report.tokenRecoverer.rely(address(report.protocolGuardian));
        // Permanent ward for ongoing adapter maintenance
        if (address(report.wormholeAdapter) != address(0)) {
            report.wormholeAdapter.rely(address(report.protocolGuardian));
        }
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.rely(address(report.protocolGuardian));
        if (address(report.layerZeroAdapter) != address(0)) {
            report.layerZeroAdapter.rely(address(report.protocolGuardian));
        }

        // Rely opsGuardian
        report.core.multiAdapter.rely(address(report.opsGuardian));
        report.core.hub.rely(address(report.opsGuardian));
        // Temporal ward for initial adapter wiring
        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.rely(address(report.opsGuardian));
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.rely(address(report.opsGuardian));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.rely(address(report.opsGuardian));

        // Rely tokenRecoverer
        report.root.rely(address(report.tokenRecoverer));

        // Rely messageDispatcher
        report.root.rely(address(report.core.messageDispatcher));
        report.tokenRecoverer.rely(address(report.core.messageDispatcher));

        // Rely messageProcessor
        report.root.rely(address(report.core.messageProcessor));
        report.tokenRecoverer.rely(address(report.core.messageProcessor));

        // Rely hub
        report.batchRequestManager.rely(address(report.core.hub));

        // Rely hubHandler
        report.batchRequestManager.rely(address(report.core.hubHandler));

        // Rely asyncRequestManager
        report.globalEscrow.rely(address(report.asyncRequestManager));
        report.refundEscrowFactory.rely(address(report.asyncRequestManager));

        // Rely asyncVaultFactory
        report.asyncRequestManager.rely(address(report.asyncVaultFactory));

        // Rely syncDepositVaultFactory
        report.syncManager.rely(address(report.syncDepositVaultFactory));
        report.asyncRequestManager.rely(address(report.syncDepositVaultFactory));

        // Rely vaultRouter
        report.routerEscrow.rely(address(report.vaultRouter));

        // Rely adminSafe
        if (address(report.layerZeroAdapter) != address(0)) {
            // Needed for setDelegate calls
            report.layerZeroAdapter.rely(address(adminSafe));
        }

        // File methods
        report.core.messageDispatcher.file("tokenRecoverer", address(report.tokenRecoverer));
        report.core.messageProcessor.file("tokenRecoverer", address(report.tokenRecoverer));

        report.opsGuardian.file("opsSafe", address(opsSafe));

        report.protocolGuardian.file("safe", address(adminSafe));

        report.refundEscrowFactory.file(bytes32("controller"), address(report.asyncRequestManager));

        report.asyncRequestManager.file("spoke", address(report.core.spoke));
        report.asyncRequestManager.file("balanceSheet", address(report.core.balanceSheet));
        report.asyncRequestManager.file("vaultRegistry", address(report.core.vaultRegistry));

        report.syncManager.file("spoke", address(report.core.spoke));
        report.syncManager.file("balanceSheet", address(report.core.balanceSheet));
        report.syncManager.file("vaultRegistry", address(report.core.vaultRegistry));

        report.batchRequestManager.file("hub", address(report.core.hub));

        // Endorse methods
        report.root.endorse(address(report.core.balanceSheet));
        report.root.endorse(address(report.asyncRequestManager));
        report.root.endorse(address(report.globalEscrow));
        report.root.endorse(address(report.vaultRouter));
    }

    function revokeFull(FullReport memory report) public onlyDeployer {
        report.root.deny(address(this));
        report.tokenRecoverer.deny(address(this));

        report.routerEscrow.deny(address(this));
        report.globalEscrow.deny(address(this));
        report.refundEscrowFactory.deny(address(this));
        report.asyncVaultFactory.deny(address(this));
        report.asyncRequestManager.deny(address(this));
        report.syncDepositVaultFactory.deny(address(this));
        report.syncManager.deny(address(this));
        report.vaultRouter.deny(address(this));

        report.freezeOnlyHook.deny(address(this));
        report.fullRestrictionsHook.deny(address(this));
        report.freelyTransferableHook.deny(address(this));
        report.redemptionRestrictionsHook.deny(address(this));

        report.batchRequestManager.deny(address(this));

        if (address(report.wormholeAdapter) != address(0)) report.wormholeAdapter.deny(address(this));
        if (address(report.axelarAdapter) != address(0)) report.axelarAdapter.deny(address(this));
        if (address(report.layerZeroAdapter) != address(0)) report.layerZeroAdapter.deny(address(this));
    }
}

contract FullDeployer is CoreDeployer {
    uint256 public constant DELAY = 48 hours;

    ISafe public adminSafe;
    ISafe public opsSafe;

    Root public root;
    TokenRecoverer public tokenRecoverer;
    ProtocolGuardian public protocolGuardian;
    OpsGuardian public opsGuardian;

    Escrow public routerEscrow;
    Escrow public globalEscrow;
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

    WormholeAdapter wormholeAdapter;
    AxelarAdapter axelarAdapter;
    LayerZeroAdapter layerZeroAdapter;

    function deployFull(FullInput memory input, FullActionBatcher batcher) public {
        adminSafe = input.adminSafe;
        opsSafe = input.opsSafe;

        // Ensure salts incorporate the intended version for ALL contracts, including root which is deployed first
        version = input.core.version;

        if (input.core.root == address(0)) {
            root = Root(
                create3(generateSalt("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, batcher)))
            );
            input.core.root = address(root);
        }

        deployCore(input.core, batcher);

        tokenRecoverer = TokenRecoverer(
            create3(
                generateSalt("tokenRecoverer"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, batcher))
            )
        );

        protocolGuardian = ProtocolGuardian(
            create3(
                generateSalt("protocolGuardian"),
                abi.encodePacked(
                    type(ProtocolGuardian).creationCode,
                    abi.encode(ISafe(address(batcher)), root, gateway, multiAdapter, messageDispatcher)
                )
            )
        );

        opsGuardian = OpsGuardian(
            create3(
                generateSalt("opsGuardian"),
                abi.encodePacked(type(OpsGuardian).creationCode, abi.encode(ISafe(address(batcher)), hub, multiAdapter))
            )
        );

        routerEscrow = Escrow(
            create3(generateSalt("routerEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(batcher)))
        );

        globalEscrow = Escrow(
            create3(generateSalt("globalEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(batcher)))
        );

        refundEscrowFactory = RefundEscrowFactory(
            create3(
                generateSalt("refundEscrowFactory"),
                abi.encodePacked(type(RefundEscrowFactory).creationCode, abi.encode(batcher))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(create3(
                    generateSalt("asyncRequestManager-2"),
                    abi.encodePacked(
                        type(AsyncRequestManager).creationCode, abi.encode(globalEscrow, refundEscrowFactory, batcher)
                    )
                ))
        );

        syncManager = SyncManager(
            create3(generateSalt("syncManager"), abi.encodePacked(type(SyncManager).creationCode, abi.encode(batcher)))
        );

        vaultRouter = VaultRouter(
            create3(
                generateSalt("vaultRouter"),
                abi.encodePacked(
                    type(VaultRouter).creationCode,
                    abi.encode(address(routerEscrow), gateway, spoke, vaultRegistry, batcher)
                )
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3(
                generateSalt("asyncVaultFactory-3"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, batcher)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                generateSalt("syncDepositVaultFactory-3"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, batcher)
                )
            )
        );

        freezeOnlyHook = FreezeOnly(
            create3(
                generateSalt("freezeOnlyHook-2"),
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(globalEscrow),
                        address(spoke),
                        batcher
                    )
                )
            )
        );

        fullRestrictionsHook = FullRestrictions(
            create3(
                generateSalt("fullRestrictionsHook-2"),
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(globalEscrow),
                        address(spoke),
                        batcher
                    )
                )
            )
        );

        freelyTransferableHook = FreelyTransferable(
            create3(
                generateSalt("freelyTransferableHook-2"),
                abi.encodePacked(
                    type(FreelyTransferable).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(globalEscrow),
                        address(spoke),
                        batcher
                    )
                )
            )
        );

        redemptionRestrictionsHook = RedemptionRestrictions(
            create3(
                generateSalt("redemptionRestrictionsHook-2"),
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(
                        address(root),
                        address(spoke),
                        address(balanceSheet),
                        address(globalEscrow),
                        address(spoke),
                        batcher
                    )
                )
            )
        );

        queueManager = QueueManager(
            create3(
                generateSalt("queueManager"),
                abi.encodePacked(
                    type(QueueManager).creationCode, abi.encode(contractUpdater, balanceSheet, address(batcher))
                )
            )
        );

        onOfframpManagerFactory = OnOfframpManagerFactory(
            create3(
                generateSalt("onOfframpManagerFactory"),
                abi.encodePacked(type(OnOfframpManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet))
            )
        );

        merkleProofManagerFactory = MerkleProofManagerFactory(
            create3(
                generateSalt("merkleProofManagerFactory"),
                abi.encodePacked(
                    type(MerkleProofManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet)
                )
            )
        );

        vaultDecoder =
            VaultDecoder(create3(generateSalt("vaultDecoder"), abi.encodePacked(type(VaultDecoder).creationCode)));

        circleDecoder =
            CircleDecoder(create3(generateSalt("circleDecoder"), abi.encodePacked(type(CircleDecoder).creationCode)));

        batchRequestManager = BatchRequestManager(
            create3(
                generateSalt("batchRequestManager"),
                abi.encodePacked(type(BatchRequestManager).creationCode, abi.encode(hubRegistry, gateway, batcher))
            )
        );

        identityValuation = IdentityValuation(
            create3(
                generateSalt("identityValuation"),
                abi.encodePacked(type(IdentityValuation).creationCode, abi.encode(hubRegistry))
            )
        );

        oracleValuation = OracleValuation(
            create3(
                generateSalt("oracleValuation"),
                abi.encodePacked(type(OracleValuation).creationCode, abi.encode(hub, hubRegistry))
            )
        );

        navManager = NAVManager(
            create3(generateSalt("navManager"), abi.encodePacked(type(NAVManager).creationCode, abi.encode(hub)))
        );

        simplePriceManager = SimplePriceManager(
            create3(
                generateSalt("simplePriceManager"),
                abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(navManager)))
            )
        );

        if (input.adapters.wormhole.shouldDeploy) {
            require(input.adapters.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(input.adapters.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");

            wormholeAdapter = WormholeAdapter(
                create3(
                    generateSalt("wormholeAdapter"),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode,
                        abi.encode(multiAdapter, input.adapters.wormhole.relayer, batcher)
                    )
                )
            );
        }

        if (input.adapters.axelar.shouldDeploy) {
            require(input.adapters.axelar.gateway != address(0), "Axelar gateway address cannot be zero");
            require(input.adapters.axelar.gasService != address(0), "Axelar gas service address cannot be zero");
            require(input.adapters.axelar.gateway.code.length > 0, "Axelar gateway must be a deployed contract");
            require(input.adapters.axelar.gasService.code.length > 0, "Axelar gas service must be a deployed contract");

            axelarAdapter = AxelarAdapter(
                create3(
                    generateSalt("axelarAdapter"),
                    abi.encodePacked(
                        type(AxelarAdapter).creationCode,
                        abi.encode(
                            multiAdapter, input.adapters.axelar.gateway, input.adapters.axelar.gasService, batcher
                        )
                    )
                )
            );
        }

        if (input.adapters.layerZero.shouldDeploy) {
            require(input.adapters.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(input.adapters.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(input.adapters.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");

            layerZeroAdapter = LayerZeroAdapter(
                create3(
                    generateSalt("layerZeroAdapter"),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        abi.encode(
                            multiAdapter, input.adapters.layerZero.endpoint, input.adapters.layerZero.delegate, batcher
                        )
                    )
                )
            );
        }

        register("root", address(root));
        register("tokenRecoverer", address(tokenRecoverer));
        register("protocolGuardian", address(protocolGuardian));
        register("opsGuardian", address(opsGuardian));

        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("refundEscrowFactory", address(refundEscrowFactory));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("syncManager", address(syncManager));
        register("vaultRouter", address(vaultRouter));

        register("freezeOnlyHook", address(freezeOnlyHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
        register("freelyTransferableHook", address(freelyTransferableHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));

        register("queueManager", address(queueManager));
        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));

        register("batchRequestManager", address(batchRequestManager));

        register("identityValuation", address(identityValuation));
        register("oracleValuation", address(oracleValuation));

        register("navManager", address(navManager));
        register("simplePriceManager", address(simplePriceManager));

        if (input.adapters.wormhole.shouldDeploy) register("wormholeAdapter", address(wormholeAdapter));
        if (input.adapters.axelar.shouldDeploy) register("axelarAdapter", address(axelarAdapter));
        if (input.adapters.layerZero.shouldDeploy) register("layerZeroAdapter", address(layerZeroAdapter));

        batcher.engageFull(_fullReport(), input.adminSafe, input.opsSafe);
    }

    function _fullReport() internal view returns (FullReport memory) {
        return FullReport(
            _coreReport(),
            root,
            tokenRecoverer,
            protocolGuardian,
            opsGuardian,
            routerEscrow,
            globalEscrow,
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
            simplePriceManager,
            wormholeAdapter,
            axelarAdapter,
            layerZeroAdapter
        );
    }

    function removeFullDeployerAccess(FullActionBatcher batcher) public {
        removeCoreDeployerAccess(batcher);
        batcher.revokeFull(_fullReport());
    }
}

function noAdaptersInput() pure returns (AdaptersInput memory) {
    return AdaptersInput({
        wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
        axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
        layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
    });
}
