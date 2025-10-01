// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {Escrow} from "../src/misc/Escrow.sol";

import {Spoke} from "../src/spoke/Spoke.sol";

import {SyncManager} from "../src/vaults/SyncManager.sol";
import {VaultRouter} from "../src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {RefundEscrowFactory} from "../src/vaults/factories/RefundEscrowFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import "forge-std/Script.sol";

struct VaultsReport {
    SpokeReport spoke;
    SyncManager syncManager;
    AsyncRequestManager asyncRequestManager;
    Escrow routerEscrow;
    Escrow globalEscrow;
    VaultRouter vaultRouter;
    AsyncVaultFactory asyncVaultFactory;
    SyncDepositVaultFactory syncDepositVaultFactory;
    RefundEscrowFactory refundEscrowFactory;
}

contract VaultsActionBatcher is SpokeActionBatcher {
    function engageVaults(VaultsReport memory report) public onlyDeployer {
        // Rely Spoke
        report.asyncVaultFactory.rely(address(report.spoke.spoke));
        report.syncDepositVaultFactory.rely(address(report.spoke.spoke));
        report.asyncRequestManager.rely(address(report.spoke.spoke));

        // Rely VaultRegistry
        report.asyncVaultFactory.rely(address(report.spoke.vaultRegistry));
        report.syncDepositVaultFactory.rely(address(report.spoke.vaultRegistry));

        // Rely ContractUpdater
        report.syncManager.rely(address(report.spoke.contractUpdater));

        // Rely async requests manager
        report.globalEscrow.rely(address(report.asyncRequestManager));
        report.refundEscrowFactory.rely(address(report.asyncRequestManager));

        // Rely Root
        report.vaultRouter.rely(address(report.spoke.common.root));
        report.asyncRequestManager.rely(address(report.spoke.common.root));
        report.syncManager.rely(address(report.spoke.common.root));
        report.routerEscrow.rely(address(report.spoke.common.root));
        report.globalEscrow.rely(address(report.spoke.common.root));
        report.asyncVaultFactory.rely(address(report.spoke.common.root));
        report.syncDepositVaultFactory.rely(address(report.spoke.common.root));
        report.refundEscrowFactory.rely(address(report.spoke.common.root));

        // Rely others
        report.routerEscrow.rely(address(report.vaultRouter));
        report.syncManager.rely(address(report.syncDepositVaultFactory));
        report.asyncRequestManager.rely(address(report.syncDepositVaultFactory));
        report.asyncRequestManager.rely(address(report.asyncVaultFactory));

        // Rely VaultRouter
        report.spoke.common.gateway.rely(address(report.vaultRouter));

        // File methods
        report.asyncRequestManager.file("spoke", address(report.spoke.spoke));
        report.asyncRequestManager.file("balanceSheet", address(report.spoke.balanceSheet));
        report.asyncRequestManager.file("vaultRegistry", address(report.spoke.vaultRegistry));

        report.syncManager.file("spoke", address(report.spoke.spoke));
        report.syncManager.file("balanceSheet", address(report.spoke.balanceSheet));
        report.syncManager.file("vaultRegistry", address(report.spoke.vaultRegistry));

        report.refundEscrowFactory.file(bytes32("controller"), address(report.asyncRequestManager));

        // Endorse methods
        report.spoke.common.root.endorse(address(report.asyncRequestManager));
        report.spoke.common.root.endorse(address(report.globalEscrow));
        report.spoke.common.root.endorse(address(report.vaultRouter));
    }

    function revokeVaults(VaultsReport memory report) public onlyDeployer {
        report.asyncVaultFactory.deny(address(this));
        report.syncDepositVaultFactory.deny(address(this));
        report.asyncRequestManager.deny(address(this));
        report.syncManager.deny(address(this));
        report.routerEscrow.deny(address(this));
        report.globalEscrow.deny(address(this));
        report.vaultRouter.deny(address(this));
        report.refundEscrowFactory.deny(address(this));
    }
}

contract VaultsDeployer is SpokeDeployer {
    SyncManager public syncManager;
    AsyncRequestManager public asyncRequestManager;
    Escrow public routerEscrow;
    Escrow public globalEscrow;
    VaultRouter public vaultRouter;
    AsyncVaultFactory public asyncVaultFactory;
    SyncDepositVaultFactory public syncDepositVaultFactory;
    RefundEscrowFactory public refundEscrowFactory;

    function deployVaults(CommonInput memory input, VaultsActionBatcher batcher) public {
        _preDeployVaults(input, batcher);
        _postDeployVaults(batcher);
    }

    function _preDeployVaults(CommonInput memory input, VaultsActionBatcher batcher) internal {
        _preDeploySpoke(input, batcher);

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
            payable(
                create3(
                    generateSalt("asyncRequestManager-2"),
                    abi.encodePacked(
                        type(AsyncRequestManager).creationCode, abi.encode(globalEscrow, refundEscrowFactory, batcher)
                    )
                )
            )
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

        batcher.engageVaults(_vaultsReport());

        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("refundEscrowFactory", address(refundEscrowFactory));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncManager", address(syncManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("vaultRouter", address(vaultRouter));
    }

    function _postDeployVaults(VaultsActionBatcher batcher) internal {
        _postDeploySpoke(batcher);
    }

    function removeVaultsDeployerAccess(VaultsActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);

        batcher.revokeVaults(_vaultsReport());
    }

    function _vaultsReport() internal view returns (VaultsReport memory) {
        return VaultsReport(
            _spokeReport(),
            syncManager,
            asyncRequestManager,
            routerEscrow,
            globalEscrow,
            vaultRouter,
            asyncVaultFactory,
            syncDepositVaultFactory,
            refundEscrowFactory
        );
    }
}
