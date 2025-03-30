// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";

import {AsyncRequests} from "src/vaults/AsyncRequests.sol";
import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";
import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {RestrictedRedemptions} from "src/vaults/token/RestrictedRedemptions.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract VaultsDeployer is CommonDeployer {
    BalanceSheetManager public balanceSheetManager;
    AsyncRequests public asyncRequests;
    SyncRequests public syncRequests;
    PoolManager public poolManager;
    Escrow public escrow;
    Escrow public routerEscrow;
    VaultRouter public vaultRouter;
    address public asyncVaultFactory;
    address public syncDepositVaultFactory;
    address public restrictionManager;
    address public restrictedRedemptions;
    address public tokenFactory;

    function deployVaults(uint16 chainId, ISafe adminSafe_, address deployer) public {
        deployCommon(chainId, adminSafe_, deployer);

        escrow = new Escrow{salt: SALT}(deployer);
        routerEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow2"))}(deployer);
        restrictionManager = address(new RestrictionManager{salt: SALT}(address(root), deployer));
        restrictedRedemptions = address(new RestrictedRedemptions{salt: SALT}(address(root), address(escrow), deployer));
        tokenFactory = address(new TokenFactory{salt: SALT}(address(root), deployer));
        asyncRequests = new AsyncRequests(address(root), address(escrow));
        syncRequests = new SyncRequests(address(root), address(escrow));
        asyncVaultFactory = address(new AsyncVaultFactory(address(root), address(asyncRequests)));
        syncDepositVaultFactory =
            address(new SyncDepositVaultFactory(address(root), address(syncRequests), address(asyncRequests)));
        address[] memory vaultFactories = new address[](2);
        vaultFactories[0] = asyncVaultFactory;
        vaultFactories[1] = syncDepositVaultFactory;

        poolManager = new PoolManager(address(escrow), tokenFactory, vaultFactories);
        balanceSheetManager = new BalanceSheetManager(address(escrow));
        vaultRouter = new VaultRouter(address(routerEscrow), address(gateway), address(poolManager));

        _vaultsRegister();
        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _vaultsRegister() private {
        register("escrow", address(escrow));
        register("routerEscrow", address(routerEscrow));
        register("restrictionManager", address(restrictionManager));
        register("restrictedRedemptions", address(restrictedRedemptions));
        register("tokenFactory", address(tokenFactory));
        register("asyncRequests", address(asyncRequests));
        register("syncRequests", address(syncRequests));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("poolManager", address(poolManager));
        register("vaultRouter", address(vaultRouter));
    }

    function _vaultsEndorse() private {
        root.endorse(address(vaultRouter));
        root.endorse(address(escrow));
    }

    function _vaultsRely() private {
        // Rely on PoolManager
        escrow.rely(address(poolManager));
        IAuth(asyncVaultFactory).rely(address(poolManager));
        IAuth(syncDepositVaultFactory).rely(address(poolManager));
        IAuth(tokenFactory).rely(address(poolManager));
        IAuth(asyncRequests).rely(address(poolManager));
        IAuth(syncRequests).rely(address(poolManager));
        IAuth(restrictionManager).rely(address(poolManager));
        IAuth(restrictedRedemptions).rely(address(poolManager));
        messageDispatcher.rely(address(poolManager));

        // Rely on async investment manager
        messageDispatcher.rely(address(asyncRequests));

        // Rely on sync investment manager
        balanceSheetManager.rely(address(syncRequests));
        asyncRequests.rely(address(syncRequests));

        // Rely on BalanceSheetManager
        messageDispatcher.rely(address(balanceSheetManager));
        escrow.rely(address(balanceSheetManager));

        // Rely on Root
        vaultRouter.rely(address(root));
        poolManager.rely(address(root));
        asyncRequests.rely(address(root));
        syncRequests.rely(address(root));
        balanceSheetManager.rely(address(root));
        escrow.rely(address(root));
        routerEscrow.rely(address(root));
        IAuth(asyncVaultFactory).rely(address(root));
        IAuth(syncDepositVaultFactory).rely(address(root));
        IAuth(tokenFactory).rely(address(root));
        IAuth(restrictionManager).rely(address(root));
        IAuth(restrictedRedemptions).rely(address(root));

        // Rely on vaultGateway
        asyncRequests.rely(address(gateway));
        poolManager.rely(address(gateway));

        // Rely on others
        routerEscrow.rely(address(vaultRouter));
        syncRequests.rely(address(syncDepositVaultFactory));

        // Rely on messageProcessor
        poolManager.rely(address(messageProcessor));
        asyncRequests.rely(address(messageProcessor));
        balanceSheetManager.rely(address(messageProcessor));

        // Rely on messageDispatcher
        poolManager.rely(address(messageDispatcher));
        asyncRequests.rely(address(messageDispatcher));
        balanceSheetManager.rely(address(messageDispatcher));

        // Rely on VaultRouter
        gateway.rely(address(vaultRouter));
        poolManager.rely(address(vaultRouter));
    }

    function _vaultsFile() public {
        messageDispatcher.file("poolManager", address(poolManager));
        messageDispatcher.file("investmentManager", address(asyncRequests));
        messageDispatcher.file("balanceSheetManager", address(asyncRequests));

        messageProcessor.file("poolManager", address(poolManager));
        messageProcessor.file("investmentManager", address(asyncRequests));
        messageProcessor.file("balanceSheetManager", address(asyncRequests));

        poolManager.file("balanceSheetManager", address(balanceSheetManager));
        poolManager.file("sender", address(messageDispatcher));

        asyncRequests.file("poolManager", address(poolManager));
        asyncRequests.file("gateway", address(gateway));
        asyncRequests.file("sender", address(messageDispatcher));

        syncRequests.file("poolManager", address(poolManager));
        syncRequests.file("balanceSheetManager", address(balanceSheetManager));

        balanceSheetManager.file("poolManager", address(poolManager));
        balanceSheetManager.file("gateway", address(gateway));
        balanceSheetManager.file("sender", address(messageDispatcher));
    }

    function removeVaultsDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        IAuth(asyncVaultFactory).deny(deployer);
        IAuth(syncDepositVaultFactory).deny(deployer);
        IAuth(tokenFactory).deny(deployer);
        IAuth(restrictionManager).deny(deployer);
        IAuth(restrictedRedemptions).deny(deployer);
        asyncRequests.deny(deployer);
        syncRequests.deny(deployer);
        poolManager.deny(deployer);
        balanceSheetManager.deny(deployer);
        escrow.deny(deployer);
        routerEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}
