// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";

import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {SyncRequestManager} from "src/vaults/SyncRequestManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {IEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {PoolEscrowFactory} from "src/vaults/factories/PoolEscrowFactory.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract VaultsDeployer is CommonDeployer {
    BalanceSheet public balanceSheet;
    AsyncRequestManager public asyncRequestManager;
    SyncRequestManager public syncRequestManager;
    PoolManager public poolManager;
    PoolEscrowFactory public poolEscrowFactory;
    Escrow public routerEscrow;
    Escrow public globalEscrow;
    VaultRouter public vaultRouter;
    AsyncVaultFactory public asyncVaultFactory;
    SyncDepositVaultFactory public syncDepositVaultFactory;
    TokenFactory public tokenFactory;

    // Hooks
    address public freezeOnlyHook;
    address public redemptionRestrictionsHook;
    address public fullRestrictionsHook;

    function deployVaults(uint16 centrifugeId, ISafe adminSafe_, address deployer, bool isTests) public {
        deployCommon(centrifugeId, adminSafe_, deployer, isTests);

        poolEscrowFactory = new PoolEscrowFactory{salt: SALT}(address(root), deployer);
        routerEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow2"))}(deployer);
        globalEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow3"))}(deployer);
        tokenFactory = new TokenFactory{salt: SALT}(address(root), deployer);

        asyncRequestManager = new AsyncRequestManager(IEscrow(globalEscrow), address(root), deployer);
        syncRequestManager = new SyncRequestManager(IEscrow(globalEscrow), address(root), deployer);
        asyncVaultFactory = new AsyncVaultFactory(address(root), asyncRequestManager, deployer);
        syncDepositVaultFactory =
            new SyncDepositVaultFactory(address(root), syncRequestManager, asyncRequestManager, deployer);

        IVaultFactory[] memory vaultFactories = new IVaultFactory[](2);
        vaultFactories[0] = asyncVaultFactory;
        vaultFactories[1] = syncDepositVaultFactory;

        poolManager = new PoolManager(tokenFactory, vaultFactories, deployer);
        balanceSheet = new BalanceSheet(root, deployer);
        vaultRouter = new VaultRouter(address(routerEscrow), gateway, poolManager, messageDispatcher, deployer);

        // Hooks
        freezeOnlyHook = address(new FreezeOnly{salt: SALT}(address(root), deployer));
        fullRestrictionsHook = address(new FullRestrictions{salt: SALT}(address(root), deployer));
        redemptionRestrictionsHook = address(new RedemptionRestrictions{salt: SALT}(address(root), deployer));

        _vaultsRegister();
        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _vaultsRegister() private {
        register("poolEscrowFactory", address(poolEscrowFactory));
        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("freezeOnlyHook", address(freezeOnlyHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
        register("tokenFactory", address(tokenFactory));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncRequestManager", address(syncRequestManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("poolManager", address(poolManager));
        register("vaultRouter", address(vaultRouter));
    }

    function _vaultsEndorse() private {
        root.endorse(address(vaultRouter));
        root.endorse(address(globalEscrow));
        root.endorse(address(balanceSheet));
    }

    function _vaultsRely() private {
        // Rely PoolManager
        IAuth(asyncVaultFactory).rely(address(poolManager));
        IAuth(syncDepositVaultFactory).rely(address(poolManager));
        IAuth(tokenFactory).rely(address(poolManager));
        asyncRequestManager.rely(address(poolManager));
        syncRequestManager.rely(address(poolManager));
        IAuth(freezeOnlyHook).rely(address(poolManager));
        IAuth(fullRestrictionsHook).rely(address(poolManager));
        IAuth(redemptionRestrictionsHook).rely(address(poolManager));
        messageDispatcher.rely(address(poolManager));
        poolEscrowFactory.rely(address(poolManager));
        gateway.rely(address(poolManager));

        // Rely async requests manager
        balanceSheet.rely(address(asyncRequestManager));
        messageDispatcher.rely(address(asyncRequestManager));
        globalEscrow.rely(address(asyncRequestManager));

        // Rely sync requests manager
        balanceSheet.rely(address(syncRequestManager));
        asyncRequestManager.rely(address(syncRequestManager));
        globalEscrow.rely(address(syncRequestManager));

        // Rely BalanceSheet
        messageDispatcher.rely(address(balanceSheet));

        // Rely Root
        vaultRouter.rely(address(root));
        poolManager.rely(address(root));
        asyncRequestManager.rely(address(root));
        syncRequestManager.rely(address(root));
        balanceSheet.rely(address(root));
        poolEscrowFactory.rely(address(root));
        routerEscrow.rely(address(root));
        globalEscrow.rely(address(root));
        IAuth(asyncVaultFactory).rely(address(root));
        IAuth(syncDepositVaultFactory).rely(address(root));
        IAuth(tokenFactory).rely(address(root));
        IAuth(freezeOnlyHook).rely(address(root));
        IAuth(fullRestrictionsHook).rely(address(root));
        IAuth(redemptionRestrictionsHook).rely(address(root));

        // Rely gateway
        asyncRequestManager.rely(address(gateway));
        poolManager.rely(address(gateway));

        // Rely others
        routerEscrow.rely(address(vaultRouter));
        syncRequestManager.rely(address(syncDepositVaultFactory));

        // Rely messageProcessor
        poolManager.rely(address(messageProcessor));
        asyncRequestManager.rely(address(messageProcessor));
        balanceSheet.rely(address(messageProcessor));

        // Rely messageDispatcher
        poolManager.rely(address(messageDispatcher));
        asyncRequestManager.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));

        // Rely VaultRouter
        gateway.rely(address(vaultRouter));
        poolManager.rely(address(vaultRouter));
    }

    function _vaultsFile() public {
        messageDispatcher.file("poolManager", address(poolManager));
        messageDispatcher.file("investmentManager", address(asyncRequestManager));
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("poolManager", address(poolManager));
        messageProcessor.file("investmentManager", address(asyncRequestManager));
        messageProcessor.file("balanceSheet", address(balanceSheet));

        poolManager.file("gateway", address(gateway));
        poolManager.file("balanceSheet", address(balanceSheet));
        poolManager.file("sender", address(messageDispatcher));
        poolManager.file("poolEscrowFactory", address(poolEscrowFactory));

        asyncRequestManager.file("sender", address(messageDispatcher));
        asyncRequestManager.file("poolManager", address(poolManager));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        asyncRequestManager.file("poolEscrowProvider", address(poolEscrowFactory));

        syncRequestManager.file("poolManager", address(poolManager));
        syncRequestManager.file("balanceSheet", address(balanceSheet));
        syncRequestManager.file("poolEscrowProvider", address(poolEscrowFactory));

        balanceSheet.file("poolManager", address(poolManager));
        balanceSheet.file("gateway", address(gateway));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

        poolEscrowFactory.file("poolManager", address(poolManager));
        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));
        poolEscrowFactory.file("asyncRequestManager", address(asyncRequestManager));
    }

    function removeVaultsDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        IAuth(asyncVaultFactory).deny(deployer);
        IAuth(syncDepositVaultFactory).deny(deployer);
        IAuth(tokenFactory).deny(deployer);
        IAuth(freezeOnlyHook).deny(deployer);
        IAuth(fullRestrictionsHook).deny(deployer);
        IAuth(redemptionRestrictionsHook).deny(deployer);
        asyncRequestManager.deny(deployer);
        syncRequestManager.deny(deployer);
        poolManager.deny(deployer);
        balanceSheet.deny(deployer);
        poolEscrowFactory.deny(deployer);
        routerEscrow.deny(deployer);
        globalEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}
