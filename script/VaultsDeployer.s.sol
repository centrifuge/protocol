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

    function deployVaults(uint16 chainId, ISafe adminSafe_) public {
        deployCommon(chainId, adminSafe_);

        escrow = new Escrow{salt: SALT}(address(this));
        routerEscrow = new Escrow{salt: keccak256(abi.encodePacked(SALT, "escrow2"))}(address(this));
        restrictionManager = address(new RestrictionManager{salt: SALT}(address(root), address(this)));
        restrictedRedemptions =
            address(new RestrictedRedemptions{salt: SALT}(address(root), address(escrow), address(this)));
        trancheFactory = address(new TrancheFactory{salt: SALT}(address(root), address(this)));
        asyncInvestmentManager = new AsyncInvestmentManager(address(root), address(escrow));
        syncInvestmentManager = new SyncInvestmentManager(address(root), address(escrow));
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
        messageDispatcher.rely(address(poolManager));

        // Rely on investment managers
        messageDispatcher.rely(address(asyncInvestmentManager));
        messageDispatcher.rely(address(syncInvestmentManager));

        // Rely on InvestmentManager

        // Rely on BalanceSheetManager
        messageDispatcher.rely(address(balanceSheetManager));
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

        // Rely on messageProcessor
        poolManager.rely(address(messageProcessor));
        asyncInvestmentManager.rely(address(messageProcessor));
        syncInvestmentManager.rely(address(messageProcessor));
        balanceSheetManager.rely(address(messageProcessor));

        poolManager.rely(address(messageDispatcher));
        asyncInvestmentManager.rely(address(messageDispatcher));
        asyncInvestmentManager.rely(address(messageDispatcher));
        balanceSheetManager.rely(address(messageDispatcher));

        // Rely on VaultRouter
        gateway.rely(address(vaultRouter));
        poolManager.rely(address(vaultRouter));
    }

    function _vaultsFile() public {
        messageDispatcher.file("poolManager", address(poolManager));
        messageDispatcher.file("investmentManager", address(asyncInvestmentManager));
        messageDispatcher.file("balanceSheetManager", address(asyncInvestmentManager));

        messageProcessor.file("poolManager", address(poolManager));
        messageProcessor.file("investmentManager", address(asyncInvestmentManager));
        messageProcessor.file("balanceSheetManager", address(asyncInvestmentManager));

        poolManager.file("balanceSheetManager", address(balanceSheetManager));
        poolManager.file("sender", address(messageDispatcher));

        asyncInvestmentManager.file("poolManager", address(poolManager));
        asyncInvestmentManager.file("gateway", address(gateway));
        asyncInvestmentManager.file("sender", address(messageDispatcher));
        syncInvestmentManager.file("poolManager", address(poolManager));
        syncInvestmentManager.file("gateway", address(gateway));
        syncInvestmentManager.file("sender", address(messageDispatcher));

        balanceSheetManager.file("poolManager", address(poolManager));
        balanceSheetManager.file("gateway", address(gateway));
        balanceSheetManager.file("sender", address(messageDispatcher));
    }

    function removeVaultsDeployerAccess() public {
        removeCommonDeployerAccess();

        IAuth(asyncVaultFactory).deny(msg.sender);
        IAuth(syncDepositAsyncRedeemVaultFactory).deny(msg.sender);
        IAuth(trancheFactory).deny(msg.sender);
        IAuth(restrictionManager).deny(msg.sender);
        IAuth(restrictedRedemptions).deny(msg.sender);
        asyncInvestmentManager.deny(msg.sender);
        syncInvestmentManager.deny(msg.sender);
        poolManager.deny(msg.sender);
        escrow.deny(msg.sender);
        routerEscrow.deny(msg.sender);
        vaultRouter.deny(msg.sender);
    }
}
