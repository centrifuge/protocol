// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";

import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {SyncRequestManager} from "src/vaults/SyncRequestManager.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {Escrow} from "src/spoke/Escrow.sol";
import {IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {PoolEscrowFactory} from "src/spoke/factories/PoolEscrowFactory.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract SpokeDeployer is CommonDeployer {
    Spoke public spoke;
    BalanceSheet public balanceSheet;
    SyncRequestManager public syncRequestManager;
    AsyncRequestManager public asyncRequestManager;
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

    function deploySpoke(uint16 centrifugeId, ISafe adminSafe_, address deployer, bool isTests) public {
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

        spoke = new Spoke(tokenFactory, deployer);
        balanceSheet = new BalanceSheet(root, deployer);
        vaultRouter = new VaultRouter(address(routerEscrow), gateway, spoke, messageDispatcher, deployer);

        // Hooks
        freezeOnlyHook = address(new FreezeOnly{salt: SALT}(address(root), deployer));
        fullRestrictionsHook = address(new FullRestrictions{salt: SALT}(address(root), deployer));
        redemptionRestrictionsHook = address(new RedemptionRestrictions{salt: SALT}(address(root), deployer));

        _spokeRegister();
        _spokeEndorse();
        _spokeRely();
        _spokeFile();
    }

    function _spokeRegister() private {
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
        register("spoke", address(spoke));
        register("vaultRouter", address(vaultRouter));
        register("balanceSheet", address(balanceSheet));
    }

    function _spokeEndorse() private {
        root.endorse(address(vaultRouter));
        root.endorse(address(globalEscrow));
        root.endorse(address(balanceSheet));
        root.endorse(address(asyncRequestManager));
    }

    function _spokeRely() private {
        // Rely Spoke
        IAuth(asyncVaultFactory).rely(address(spoke));
        IAuth(syncDepositVaultFactory).rely(address(spoke));
        IAuth(tokenFactory).rely(address(spoke));
        asyncRequestManager.rely(address(spoke));
        syncRequestManager.rely(address(spoke));
        IAuth(freezeOnlyHook).rely(address(spoke));
        IAuth(fullRestrictionsHook).rely(address(spoke));
        IAuth(redemptionRestrictionsHook).rely(address(spoke));
        messageDispatcher.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        gateway.rely(address(spoke));

        // Rely async requests manager
        globalEscrow.rely(address(asyncRequestManager));

        // Rely sync requests manager
        balanceSheet.rely(address(syncRequestManager));
        asyncRequestManager.rely(address(syncRequestManager));

        // Rely BalanceSheet
        messageDispatcher.rely(address(balanceSheet));

        // Rely Root
        vaultRouter.rely(address(root));
        spoke.rely(address(root));
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
        spoke.rely(address(gateway));

        // Rely others
        routerEscrow.rely(address(vaultRouter));

        // Rely messageProcessor
        spoke.rely(address(messageProcessor));
        balanceSheet.rely(address(messageProcessor));

        // Rely messageDispatcher
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));

        // Rely VaultRouter
        gateway.rely(address(vaultRouter));
        spoke.rely(address(vaultRouter));
    }

    function _spokeFile() public {
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("spoke", address(spoke));
        messageProcessor.file("balanceSheet", address(balanceSheet));

        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));
        spoke.file("vaultFactory", address(asyncVaultFactory), true);
        spoke.file("vaultFactory", address(syncDepositVaultFactory), true);

        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));

        syncRequestManager.file("spoke", address(spoke));
        syncRequestManager.file("balanceSheet", address(balanceSheet));

        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(spoke);
        tokenWards[1] = address(balanceSheet);

        tokenFactory.file("wards", tokenWards);
    }

    function removeSpokeDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        IAuth(asyncVaultFactory).deny(deployer);
        IAuth(syncDepositVaultFactory).deny(deployer);
        IAuth(tokenFactory).deny(deployer);
        IAuth(freezeOnlyHook).deny(deployer);
        IAuth(fullRestrictionsHook).deny(deployer);
        IAuth(redemptionRestrictionsHook).deny(deployer);
        asyncRequestManager.deny(deployer);
        syncRequestManager.deny(deployer);
        spoke.deny(deployer);
        balanceSheet.deny(deployer);
        poolEscrowFactory.deny(deployer);
        routerEscrow.deny(deployer);
        globalEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}
