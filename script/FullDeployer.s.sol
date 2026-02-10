// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CoreDeployer} from "./CoreDeployer.s.sol";

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

import "forge-std/Script.sol";

import {SubsidyManager} from "../src/utils/SubsidyManager.sol";
import {AxelarAdapter} from "../src/adapters/AxelarAdapter.sol";
import {WormholeAdapter} from "../src/adapters/WormholeAdapter.sol";
import {ChainlinkAdapter} from "../src/adapters/ChainlinkAdapter.sol";
import {LayerZeroAdapter} from "../src/adapters/LayerZeroAdapter.sol";
import {RefundEscrowFactory} from "../src/utils/RefundEscrowFactory.sol";
import {
    FullActionBatcher,
    AdapterActionBatcher,
    FullInput,
    FullReport,
    AdaptersReport,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    AdapterConnections,
    SetConfigParam
} from "../src/deployer/ActionBatchers.sol";

contract FullDeployer is CoreDeployer {
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

    FullActionBatcher public batcher;
    AdapterActionBatcher public adapterBatcher;

    function deployFull(FullInput memory input, address deployer_) public {
        _init(input.core.version, deployer_);

        batcher = new FullActionBatcher(deployer_);
        adapterBatcher = new AdapterActionBatcher(deployer_);

        deployCore(input.core, batcher);

        refundEscrowFactory = RefundEscrowFactory(
            create3(
                generateSalt("refundEscrowFactory"),
                abi.encodePacked(type(RefundEscrowFactory).creationCode, abi.encode(batcher))
            )
        );

        subsidyManager = SubsidyManager(
            create3(
                generateSalt("subsidyManager"),
                abi.encodePacked(type(SubsidyManager).creationCode, abi.encode(refundEscrowFactory, batcher))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(create3(
                    generateSalt("asyncRequestManager"),
                    abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(subsidyManager, batcher))
                ))
        );

        syncManager = SyncManager(
            create3(generateSalt("syncManager"), abi.encodePacked(type(SyncManager).creationCode, abi.encode(batcher)))
        );

        vaultRouter = VaultRouter(
            create3(
                generateSalt("vaultRouter"),
                abi.encodePacked(type(VaultRouter).creationCode, abi.encode(gateway, spoke, vaultRegistry, batcher))
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3(
                generateSalt("asyncVaultFactory"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, batcher)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                generateSalt("syncDepositVaultFactory"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, batcher)
                )
            )
        );

        freezeOnlyHook = FreezeOnly(
            create3(
                generateSalt("freezeOnlyHook"),
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
                generateSalt("fullRestrictionsHook"),
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
                generateSalt("freelyTransferableHook"),
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
                generateSalt("redemptionRestrictionsHook"),
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

        if (input.adapters.layerZero.shouldDeploy) {
            require(input.adapters.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(input.adapters.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(input.adapters.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");
            require(
                input.adapters.layerZero.configParams.length == 0
                    || input.adapters.layerZero.configParams.length == input.adapters.connections.length,
                "configParams must mimics connections"
            );

            layerZeroAdapter = LayerZeroAdapter(
                create3(
                    generateSalt("layerZeroAdapter"),
                    abi.encodePacked(
                        type(LayerZeroAdapter).creationCode,
                        // Set delegate to adapterBatcher initially, to be able to set ULN config
                        abi.encode(multiAdapter, input.adapters.layerZero.endpoint, adapterBatcher, adapterBatcher)
                    )
                )
            );
        }

        if (input.adapters.wormhole.shouldDeploy) {
            require(input.adapters.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(input.adapters.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");

            wormholeAdapter = WormholeAdapter(
                create3(
                    generateSalt("wormholeAdapter"),
                    abi.encodePacked(
                        type(WormholeAdapter).creationCode,
                        abi.encode(multiAdapter, input.adapters.wormhole.relayer, adapterBatcher)
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
                            multiAdapter,
                            input.adapters.axelar.gateway,
                            input.adapters.axelar.gasService,
                            adapterBatcher
                        )
                    )
                )
            );
        }

        if (input.adapters.chainlink.shouldDeploy) {
            require(input.adapters.chainlink.ccipRouter != address(0), "Chainlink ccipRouter address cannot be zero");
            require(
                input.adapters.chainlink.ccipRouter.code.length > 0, "Chainlink ccipRouter must be a deployed contract"
            );

            chainlinkAdapter = ChainlinkAdapter(
                create3(
                    generateSalt("chainlinkAdapter"),
                    abi.encodePacked(
                        type(ChainlinkAdapter).creationCode,
                        abi.encode(multiAdapter, input.adapters.chainlink.ccipRouter, adapterBatcher)
                    )
                )
            );
        }

        register("refundEscrowFactory", address(refundEscrowFactory));
        register("subsidyManager", address(subsidyManager));
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
        if (input.adapters.chainlink.shouldDeploy) register("chainlinkAdapter", address(chainlinkAdapter));

        batcher.engageFull(fullReport(), address(adapterBatcher));
        adapterBatcher.engageAdapters(adaptersReport(), input, vm.toString(address(axelarAdapter)));
    }

    function fullReport() public view returns (FullReport memory) {
        return FullReport(
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
        return AdaptersReport(fullReport(), layerZeroAdapter, wormholeAdapter, axelarAdapter, chainlinkAdapter);
    }

    function removeFullDeployerAccess() public {
        removeCoreDeployerAccess(batcher);
        batcher.revokeFull(fullReport());
        adapterBatcher.revokeAdapters(adaptersReport());

        batcher.lock();
        adapterBatcher.lock();
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
