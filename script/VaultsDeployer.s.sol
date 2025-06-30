// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Escrow} from "src/misc/Escrow.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

import {SyncManager} from "src/vaults/SyncManager.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";

import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";

import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";

contract VaultsDeployer is SpokeDeployer {
    SyncManager public syncManager;
    AsyncRequestManager public asyncRequestManager;
    Escrow public routerEscrow;
    Escrow public globalEscrow;
    VaultRouter public vaultRouter;
    AsyncVaultFactory public asyncVaultFactory;
    SyncDepositVaultFactory public syncDepositVaultFactory;

    function deployVaults(CommonInput memory input, address deployer) public {
        deploySpoke(input, deployer);

        routerEscrow = Escrow(
            create3(generateSalt("routerEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(deployer)))
        );

        globalEscrow = Escrow(
            create3(generateSalt("globalEscrow"), abi.encodePacked(type(Escrow).creationCode, abi.encode(deployer)))
        );

        asyncRequestManager = AsyncRequestManager(
            create3(
                generateSalt("asyncRequestManager"),
                abi.encodePacked(type(AsyncRequestManager).creationCode, abi.encode(IEscrow(globalEscrow), deployer))
            )
        );

        syncManager = SyncManager(
            create3(generateSalt("syncManager"), abi.encodePacked(type(SyncManager).creationCode, abi.encode(deployer)))
        );

        vaultRouter = VaultRouter(
            create3(
                generateSalt("vaultRouter"),
                abi.encodePacked(
                    type(VaultRouter).creationCode, abi.encode(address(routerEscrow), gateway, spoke, deployer)
                )
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3(
                generateSalt("asyncVaultFactory"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, deployer)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                generateSalt("syncDepositVaultFactory"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, deployer)
                )
            )
        );

        _vaultsRegister();
        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _vaultsRegister() private {
        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncManager", address(syncManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("vaultRouter", address(vaultRouter));
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
