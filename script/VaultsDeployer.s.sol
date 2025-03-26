// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";

import {AsyncInvestmentManager} from "src/vaults/AsyncInvestmentManager.sol";
import {BalanceSheetManager} from "src/vaults/BalanceSheetManager.sol";
import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";
import {ERC7540VaultFactory} from "src/vaults/factories/ERC7540VaultFactory.sol";
import {SyncDepositAsyncRedeemVaultFactory} from "src/vaults/factories/SyncDepositAsyncRedeemVaultFactory.sol";
import {RestrictionManager} from "src/vaults/token/RestrictionManager.sol";
import {RestrictedRedemptions} from "src/vaults/token/RestrictedRedemptions.sol";
import {SyncInvestmentManager} from "src/vaults/SyncInvestmentManager.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract VaultsDeployer is CommonDeployer {
    BalanceSheetManager public balanceSheetManager;
    AsyncInvestmentManager public asyncInvestmentManager;
    SyncInvestmentManager public syncInvestmentManager;
    PoolManager public poolManager;
    Escrow public escrow;
    Escrow public routerEscrow;
    VaultRouter public vaultRouter;
    address public asyncVaultFactory;
    address public syncDepositAsyncRedeemVaultFactory;
    address public restrictionManager;
    address public restrictedRedemptions;
    address public trancheFactory;

    function deployVaults(ISafe adminSafe_, address deployer) public {
        deployCommon(adminSafe_, deployer);

        escrow = new Escrow{salt: SALT}(deployer);
        routerEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow2"))}(deployer);
        restrictionManager = address(new RestrictionManager{salt: SALT}(address(root), deployer));
        restrictedRedemptions = address(new RestrictedRedemptions{salt: SALT}(address(root), address(escrow), deployer));
        trancheFactory = address(new TrancheFactory{salt: SALT}(address(root), deployer));
        asyncInvestmentManager = new AsyncInvestmentManager(address(root), address(escrow));
        syncInvestmentManager = new SyncInvestmentManager(address(root), address(escrow));
        IBaseInvestmentManager[] memory investmentManagers;
        asyncVaultFactory = address(new ERC7540VaultFactory(address(root), address(asyncInvestmentManager)));
        syncDepositAsyncRedeemVaultFactory = address(
            new SyncDepositAsyncRedeemVaultFactory(
                address(root), address(syncInvestmentManager), address(asyncInvestmentManager)
            )
        );

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = asyncVaultFactory;
        vaultFactories[1] = syncDepositAsyncRedeemVaultFactory;

        poolManager = new PoolManager(address(escrow), trancheFactory, vaultFactories);
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
        register("trancheFactory", address(trancheFactory));
        register("asyncInvestmentManager", address(asyncInvestmentManager));
        register("syncInvestmentManager", address(syncInvestmentManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositAsyncRedeemVaultFactory", address(syncDepositAsyncRedeemVaultFactory));
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
        IAuth(syncDepositAsyncRedeemVaultFactory).rely(address(poolManager));
        IAuth(trancheFactory).rely(address(poolManager));
        IAuth(asyncInvestmentManager).rely(address(poolManager));
        IAuth(syncInvestmentManager).rely(address(poolManager));
        IAuth(restrictionManager).rely(address(poolManager));
        IAuth(restrictedRedemptions).rely(address(poolManager));
        messageProcessor.rely(address(poolManager));

        // Rely on investment managers
        messageProcessor.rely(address(asyncInvestmentManager));
        messageProcessor.rely(address(syncInvestmentManager));

        // Rely on BalanceSheetManager
        messageProcessor.rely(address(balanceSheetManager));
        escrow.rely(address(balanceSheetManager));

        // Rely on Root
        vaultRouter.rely(address(root));
        poolManager.rely(address(root));
        asyncInvestmentManager.rely(address(root));
        syncInvestmentManager.rely(address(root));
        balanceSheetManager.rely(address(root));
        escrow.rely(address(root));
        routerEscrow.rely(address(root));
        IAuth(asyncVaultFactory).rely(address(root));
        IAuth(syncDepositAsyncRedeemVaultFactory).rely(address(root));
        IAuth(trancheFactory).rely(address(root));
        IAuth(restrictionManager).rely(address(root));
        IAuth(restrictedRedemptions).rely(address(root));

        // Rely on vaultGateway
        asyncInvestmentManager.rely(address(gateway));
        syncInvestmentManager.rely(address(gateway));
        poolManager.rely(address(gateway));

        // Rely on others
        routerEscrow.rely(address(vaultRouter));
        syncInvestmentManager.rely(address(syncDepositAsyncRedeemVaultFactory));

        // Rely on vaultMessageProcessor
        poolManager.rely(address(messageProcessor));
        asyncInvestmentManager.rely(address(messageProcessor));
        syncInvestmentManager.rely(address(messageProcessor));
        balanceSheetManager.rely(address(messageProcessor));

        // Rely on VaultRouter
        gateway.rely(address(vaultRouter));
        poolManager.rely(address(vaultRouter));
    }

    function _vaultsFile() public {
        messageProcessor.file("poolManager", address(poolManager));

        poolManager.file("sender", address(messageProcessor));
        poolManager.file("balanceSheetManager", address(balanceSheetManager));

        asyncInvestmentManager.file("poolManager", address(poolManager));
        asyncInvestmentManager.file("gateway", address(gateway));
        asyncInvestmentManager.file("sender", address(messageProcessor));

        syncInvestmentManager.file("poolManager", address(poolManager));
        syncInvestmentManager.file("gateway", address(gateway));
        syncInvestmentManager.file("sender", address(messageProcessor));

        balanceSheetManager.file("poolManager", address(poolManager));
        balanceSheetManager.file("gateway", address(gateway));
        balanceSheetManager.file("sender", address(messageProcessor));
    }

    function removeVaultsDeployerAccess(address deployer) public {
        removeCommonDeployerAccess(deployer);

        IAuth(asyncVaultFactory).deny(deployer);
        IAuth(syncDepositAsyncRedeemVaultFactory).deny(deployer);
        IAuth(trancheFactory).deny(deployer);
        IAuth(restrictionManager).deny(deployer);
        IAuth(restrictedRedemptions).deny(deployer);
        asyncInvestmentManager.deny(deployer);
        syncInvestmentManager.deny(deployer);
        poolManager.deny(deployer);
        escrow.deny(deployer);
        routerEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}
