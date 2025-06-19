// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Escrow} from "src/misc/Escrow.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

import {ISafe} from "src/common/Guardian.sol";

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

import {CommonDeployer} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

contract SpokeDeployer is CommonDeployer {
    Spoke public spoke;
    BalanceSheet public balanceSheet;
    SyncManager public syncManager;
    AsyncRequestManager public asyncRequestManager;
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

    function deploySpoke(uint16 centrifugeId_, ISafe adminSafe_, address deployer, bool isTests) public virtual {
        deployCommon(centrifugeId_, adminSafe_, deployer, isTests);

        // Get the base salt from the FullDeployer
        bytes32 baseSalt = getBaseSalt();
        
        console.log("Deploying Spoke contracts with CreateX...");

        // RouterEscrow
        bytes32 routerEscrowSalt = keccak256(abi.encodePacked(baseSalt, "routerEscrow"));
        bytes memory routerEscrowBytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(deployer)
        );
        routerEscrow = Escrow(create3(routerEscrowSalt, routerEscrowBytecode));
        console.log("RouterEscrow deployed at:", address(routerEscrow));

        // GlobalEscrow
        bytes32 globalEscrowSalt = keccak256(abi.encodePacked(baseSalt, "globalEscrow"));
        bytes memory globalEscrowBytecode = abi.encodePacked(
            type(Escrow).creationCode,
            abi.encode(deployer)
        );
        globalEscrow = Escrow(create3(globalEscrowSalt, globalEscrowBytecode));
        console.log("GlobalEscrow deployed at:", address(globalEscrow));

        // TokenFactory
        bytes32 tokenFactorySalt = keccak256(abi.encodePacked(baseSalt, "tokenFactory"));
        bytes memory tokenFactoryBytecode = abi.encodePacked(
            type(TokenFactory).creationCode,
            abi.encode(address(root), deployer)
        );
        tokenFactory = TokenFactory(create3(tokenFactorySalt, tokenFactoryBytecode));
        console.log("TokenFactory deployed at:", address(tokenFactory));

        // AsyncRequestManager
        bytes32 asyncRequestManagerSalt = keccak256(abi.encodePacked(baseSalt, "asyncRequestManager"));
        bytes memory asyncRequestManagerBytecode = abi.encodePacked(
            type(AsyncRequestManager).creationCode,
            abi.encode(IEscrow(globalEscrow), deployer)
        );
        asyncRequestManager = AsyncRequestManager(create3(asyncRequestManagerSalt, asyncRequestManagerBytecode));
        console.log("AsyncRequestManager deployed at:", address(asyncRequestManager));

        // SyncManager
        bytes32 syncManagerSalt = keccak256(abi.encodePacked(baseSalt, "syncManager"));
        bytes memory syncManagerBytecode = abi.encodePacked(
            type(SyncManager).creationCode,
            abi.encode(deployer)
        );
        syncManager = SyncManager(create3(syncManagerSalt, syncManagerBytecode));
        console.log("SyncManager deployed at:", address(syncManager));

        // AsyncVaultFactory
        bytes32 asyncVaultFactorySalt = keccak256(abi.encodePacked(baseSalt, "asyncVaultFactory"));
        bytes memory asyncVaultFactoryBytecode = abi.encodePacked(
            type(AsyncVaultFactory).creationCode,
            abi.encode(address(root), asyncRequestManager, deployer)
        );
        asyncVaultFactory = AsyncVaultFactory(create3(asyncVaultFactorySalt, asyncVaultFactoryBytecode));
        console.log("AsyncVaultFactory deployed at:", address(asyncVaultFactory));

        // SyncDepositVaultFactory
        bytes32 syncDepositVaultFactorySalt = keccak256(abi.encodePacked(baseSalt, "syncDepositVaultFactory"));
        bytes memory syncDepositVaultFactoryBytecode = abi.encodePacked(
            type(SyncDepositVaultFactory).creationCode,
            abi.encode(address(root), syncManager, asyncRequestManager, deployer)
        );
        syncDepositVaultFactory = SyncDepositVaultFactory(create3(syncDepositVaultFactorySalt, syncDepositVaultFactoryBytecode));
        console.log("SyncDepositVaultFactory deployed at:", address(syncDepositVaultFactory));

        // Spoke
        bytes32 spokeSalt = keccak256(abi.encodePacked(baseSalt, "spoke"));
        bytes memory spokeBytecode = abi.encodePacked(
            type(Spoke).creationCode,
            abi.encode(tokenFactory, deployer)
        );
        spoke = Spoke(create3(spokeSalt, spokeBytecode));
        console.log("Spoke deployed at:", address(spoke));

        // BalanceSheet
        bytes32 balanceSheetSalt = keccak256(abi.encodePacked(baseSalt, "balanceSheet"));
        bytes memory balanceSheetBytecode = abi.encodePacked(
            type(BalanceSheet).creationCode,
            abi.encode(root, deployer)
        );
        balanceSheet = BalanceSheet(create3(balanceSheetSalt, balanceSheetBytecode));
        console.log("BalanceSheet deployed at:", address(balanceSheet));

        // VaultRouter
        bytes32 vaultRouterSalt = keccak256(abi.encodePacked(baseSalt, "vaultRouter"));
        bytes memory vaultRouterBytecode = abi.encodePacked(
            type(VaultRouter).creationCode,
            abi.encode(address(routerEscrow), gateway, spoke, deployer)
        );
        vaultRouter = VaultRouter(create3(vaultRouterSalt, vaultRouterBytecode));
        console.log("VaultRouter deployed at:", address(vaultRouter));

        // Hooks - deploy using CreateX
        bytes32 freezeOnlySalt = keccak256(abi.encodePacked(baseSalt, "freezeOnlyHook"));
        bytes memory freezeOnlyBytecode = abi.encodePacked(
            type(FreezeOnly).creationCode,
            abi.encode(address(root), deployer)
        );
        freezeOnlyHook = create3(freezeOnlySalt, freezeOnlyBytecode);
        console.log("FreezeOnlyHook deployed at:", freezeOnlyHook);

        bytes32 fullRestrictionsSalt = keccak256(abi.encodePacked(baseSalt, "fullRestrictionsHook"));
        bytes memory fullRestrictionsBytecode = abi.encodePacked(
            type(FullRestrictions).creationCode,
            abi.encode(address(root), deployer)
        );
        fullRestrictionsHook = create3(fullRestrictionsSalt, fullRestrictionsBytecode);
        console.log("FullRestrictionsHook deployed at:", fullRestrictionsHook);

        bytes32 redemptionRestrictionsSalt = keccak256(abi.encodePacked(baseSalt, "redemptionRestrictionsHook"));
        bytes memory redemptionRestrictionsBytecode = abi.encodePacked(
            type(RedemptionRestrictions).creationCode,
            abi.encode(address(root), deployer)
        );
        redemptionRestrictionsHook = create3(redemptionRestrictionsSalt, redemptionRestrictionsBytecode);
        console.log("RedemptionRestrictionsHook deployed at:", redemptionRestrictionsHook);

        _spokeRegister();
        _spokeEndorse();
        _spokeRely();
        _spokeFile();
    }

    function _spokeRegister() private {
        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("freezeOnlyHook", address(freezeOnlyHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
        register("tokenFactory", address(tokenFactory));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncManager", address(syncManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("spoke", address(spoke));
        register("vaultRouter", address(vaultRouter));
        register("balanceSheet", address(balanceSheet));
    }

    function _spokeEndorse() private {
        root.endorse(address(balanceSheet));
        root.endorse(address(asyncRequestManager));
        root.endorse(address(globalEscrow));
        root.endorse(address(vaultRouter));
    }

    function _spokeRely() private {
        // Rely Spoke
        IAuth(asyncVaultFactory).rely(address(spoke));
        IAuth(syncDepositVaultFactory).rely(address(spoke));
        IAuth(tokenFactory).rely(address(spoke));
        asyncRequestManager.rely(address(spoke));
        syncManager.rely(address(spoke));
        IAuth(freezeOnlyHook).rely(address(spoke));
        IAuth(fullRestrictionsHook).rely(address(spoke));
        IAuth(redemptionRestrictionsHook).rely(address(spoke));
        messageDispatcher.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        gateway.rely(address(spoke));

        // Rely async requests manager
        globalEscrow.rely(address(asyncRequestManager));

        // Rely BalanceSheet
        messageDispatcher.rely(address(balanceSheet));
        gateway.rely(address(balanceSheet));

        // Rely Root
        vaultRouter.rely(address(root));
        spoke.rely(address(root));
        asyncRequestManager.rely(address(root));
        syncManager.rely(address(root));
        balanceSheet.rely(address(root));
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
        syncManager.rely(address(syncDepositVaultFactory));

        // Rely messageProcessor
        spoke.rely(address(messageProcessor));
        balanceSheet.rely(address(messageProcessor));

        // Rely messageDispatcher
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));

        // Rely VaultRouter
        gateway.rely(address(vaultRouter));
    }

    function _spokeFile() public {
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("spoke", address(spoke));
        messageProcessor.file("balanceSheet", address(balanceSheet));

        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));

        syncManager.file("spoke", address(spoke));
        syncManager.file("balanceSheet", address(balanceSheet));

        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("gateway", address(gateway));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

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
        syncManager.deny(deployer);
        spoke.deny(deployer);
        balanceSheet.deny(deployer);
        routerEscrow.deny(deployer);
        globalEscrow.deny(deployer);
        vaultRouter.deny(deployer);
    }
}
