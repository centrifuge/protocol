// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Escrow} from "src/misc/Escrow.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

import {SyncManager} from "src/vaults/SyncManager.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";

import {Spoke} from "src/spoke/Spoke.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer, SpokeCBD} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";

contract VaultsCBD is SpokeCBD {
    SyncManager public syncManager;
    AsyncRequestManager public asyncRequestManager;
    Escrow public routerEscrow;
    Escrow public globalEscrow;
    VaultRouter public vaultRouter;
    AsyncVaultFactory public asyncVaultFactory;
    SyncDepositVaultFactory public syncDepositVaultFactory;

    function deployVaults(CommonInput memory input, ICreateX createX, address deployer) public {
        deploySpoke(input, createX, deployer);

        routerEscrow = Escrow(
            createX.deployCreate3(
                generateSalt("routerEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(deployer))
            )
        );

        globalEscrow = Escrow(
            createX.deployCreate3(
                generateSalt("globalEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(deployer))
            )
        );

        asyncRequestManager = AsyncRequestManager(
            createX.deployCreate3(
                generateSalt("asyncRequestManager"),
                abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(IEscrow(globalEscrow), deployer))
            )
        );

        syncManager = SyncManager(
            createX.deployCreate3(
                generateSalt("syncManager"), abi.encodePacked(type(SyncManager).creationCode, abi.encode(deployer))
            )
        );

        vaultRouter = VaultRouter(
            createX.deployCreate3(
                generateSalt("vaultRouter"),
                abi.encodePacked(
                    type(VaultRouter).creationCode, abi.encode(address(routerEscrow), gateway, spoke, deployer)
                )
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            createX.deployCreate3(
                generateSalt("asyncVaultFactory"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, deployer)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            createX.deployCreate3(
                generateSalt("syncDepositVaultFactory"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, deployer)
                )
            )
        );

        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _vaultsEndorse() private {
        root.endorse(address(asyncRequestManager));
        root.endorse(address(globalEscrow));
        root.endorse(address(vaultRouter));
    }

    function _vaultsRely() private {
        // Rely Spoke
        asyncVaultFactory.rely(address(spoke));
        syncDepositVaultFactory.rely(address(spoke));
        asyncRequestManager.rely(address(spoke));
        syncManager.rely(address(spoke));

        // Rely async requests manager
        globalEscrow.rely(address(asyncRequestManager));

        // Rely Root
        vaultRouter.rely(address(root));
        asyncRequestManager.rely(address(root));
        syncManager.rely(address(root));
        routerEscrow.rely(address(root));
        globalEscrow.rely(address(root));
        asyncVaultFactory.rely(address(root));
        syncDepositVaultFactory.rely(address(root));

        // Rely others
        routerEscrow.rely(address(vaultRouter));
        syncManager.rely(address(syncDepositVaultFactory));

        // Rely VaultRouter
        gateway.rely(address(vaultRouter));
    }

    function _vaultsFile() public {
        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));

        syncManager.file("spoke", address(spoke));
        syncManager.file("balanceSheet", address(balanceSheet));
    }

    function removeVaultsDeployerAccess(address deployer) public {
        removeSpokeDeployerAccess(deployer);

        asyncVaultFactory.deny(deployer);
        syncDepositVaultFactory.deny(deployer);
        asyncRequestManager.deny(deployer);
        syncManager.deny(deployer);
        routerEscrow.deny(deployer);
        globalEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}

contract VaultsDeployer is SpokeDeployer, VaultsCBD {
    function deployVaults(CommonInput memory input, address deployer) public {
        super.deployVaults(input, _createX(), deployer);
    }

    function vaultsRegister() internal {
        spokeRegister();
        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncManager", address(syncManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("vaultRouter", address(vaultRouter));
    }
}
