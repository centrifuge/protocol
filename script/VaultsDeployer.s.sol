// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Create3Factory} from "src/common/Create3Factory.sol";

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

    function deployVaults(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) public {
        deployCommon(centrifugeId, adminSafe_, deployer, isTests);

        _deployEscrows(deployer);
        _deployFactories(deployer);
        _deployRequestManagers(deployer);
        _deployVaultFactories(deployer);
        _deployPoolManager(deployer);
        _deployBalanceSheet(deployer);
        _deployVaultRouter(deployer);
        _deployHooks(deployer);

        _vaultsRegister();
        _vaultsEndorse();
        _vaultsRely();
        _vaultsFile();
    }

    function _deployEscrows(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        routerEscrow = Escrow(
            create3Factory.deploy(
                keccak256(abi.encodePacked("router-escrow")),
                abi.encodePacked(
                    type(Escrow).creationCode,
                    abi.encode(deployer)
                )
            )
        );

        globalEscrow = Escrow(
            create3Factory.deploy(
                keccak256(abi.encodePacked("global-escrow")),
                abi.encodePacked(
                    type(Escrow).creationCode,
                    abi.encode(deployer)
                )
            )
        );
    }

    function _deployFactories(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3Factory.deploy(
                keccak256(abi.encodePacked("pool-escrow-factory")),
                abi.encodePacked(
                    type(PoolEscrowFactory).creationCode,
                    abi.encode(address(root), deployer)
                )
            )
        );

        tokenFactory = TokenFactory(
            create3Factory.deploy(
                keccak256(abi.encodePacked("token-factory")),
                abi.encodePacked(
                    type(TokenFactory).creationCode,
                    abi.encode(address(root), deployer)
                )
            )
        );
    }

    function _deployRequestManagers(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        asyncRequestManager = AsyncRequestManager(
            create3Factory.deploy(
                keccak256(abi.encodePacked("async-request-manager")),
                abi.encodePacked(
                    type(AsyncRequestManager).creationCode,
                    abi.encode(IEscrow(globalEscrow), address(root), deployer)
                )
            )
        );

        syncRequestManager = SyncRequestManager(
            create3Factory.deploy(
                keccak256(abi.encodePacked("sync-request-manager")),
                abi.encodePacked(
                    type(SyncRequestManager).creationCode,
                    abi.encode(IEscrow(globalEscrow), address(root), deployer)
                )
            )
        );
    }

    function _deployVaultFactories(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        asyncVaultFactory = AsyncVaultFactory(
            create3Factory.deploy(
                keccak256(abi.encodePacked("async-vault-factory")),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode,
                    abi.encode(address(root), asyncRequestManager, deployer)
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            create3Factory.deploy(
                keccak256(abi.encodePacked("sync-deposit-vault-factory")),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(
                        address(root),
                        syncRequestManager,
                        asyncRequestManager,
                        deployer
                    )
                )
            )
        );
    }

    function _deployPoolManager(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        poolManager = PoolManager(
            create3Factory.deploy(
                keccak256(abi.encodePacked("pool-manager")),
                abi.encodePacked(
                    type(PoolManager).creationCode,
                    abi.encode(tokenFactory, deployer)
                )
            )
        );
    }

    function _deployBalanceSheet(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        balanceSheet = BalanceSheet(
            create3Factory.deploy(
                keccak256(abi.encodePacked("balance-sheet")),
                abi.encodePacked(
                    type(BalanceSheet).creationCode,
                    abi.encode(root, deployer)
                )
            )
        );
    }

    function _deployVaultRouter(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        vaultRouter = VaultRouter(
            create3Factory.deploy(
                keccak256(abi.encodePacked("vault-router")),
                abi.encodePacked(
                    type(VaultRouter).creationCode,
                    abi.encode(
                        address(routerEscrow),
                        gateway,
                        poolManager,
                        messageDispatcher,
                        deployer
                    )
                )
            )
        );
    }

    function _deployHooks(address deployer) internal {
        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        freezeOnlyHook = address(
            create3Factory.deploy(
                keccak256(abi.encodePacked("freeze-only-hook")),
                abi.encodePacked(
                    type(FreezeOnly).creationCode,
                    abi.encode(address(root), deployer)
                )
            )
        );

        fullRestrictionsHook = address(
            create3Factory.deploy(
                keccak256(abi.encodePacked("full-restrictions-hook")),
                abi.encodePacked(
                    type(FullRestrictions).creationCode,
                    abi.encode(address(root), deployer)
                )
            )
        );

        redemptionRestrictionsHook = address(
            create3Factory.deploy(
                keccak256(abi.encodePacked("redemption-restrictions-hook")),
                abi.encodePacked(
                    type(RedemptionRestrictions).creationCode,
                    abi.encode(address(root), deployer)
                )
            )
        );
    }

    function _vaultsRegister() private {
        register("poolEscrowFactory", address(poolEscrowFactory));
        register("routerEscrow", address(routerEscrow));
        register("globalEscrow", address(globalEscrow));
        register("freezeOnlyHook", address(freezeOnlyHook));
        register(
            "redemptionRestrictionsHook",
            address(redemptionRestrictionsHook)
        );
        register("fullRestrictionsHook", address(fullRestrictionsHook));
        register("tokenFactory", address(tokenFactory));
        register("asyncRequestManager", address(asyncRequestManager));
        register("syncRequestManager", address(syncRequestManager));
        register("asyncVaultFactory", address(asyncVaultFactory));
        register("syncDepositVaultFactory", address(syncDepositVaultFactory));
        register("poolManager", address(poolManager));
        register("vaultRouter", address(vaultRouter));
        register("balanceSheet", address(balanceSheet));
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
        messageDispatcher.file(
            "investmentManager",
            address(asyncRequestManager)
        );
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("poolManager", address(poolManager));
        messageProcessor.file(
            "investmentManager",
            address(asyncRequestManager)
        );
        messageProcessor.file("balanceSheet", address(balanceSheet));

        poolManager.file("gateway", address(gateway));
        poolManager.file("balanceSheet", address(balanceSheet));
        poolManager.file("sender", address(messageDispatcher));
        poolManager.file("poolEscrowFactory", address(poolEscrowFactory));
        poolManager.file("asyncRequestManager", address(asyncRequestManager));
        poolManager.file("syncRequestManager", address(syncRequestManager));
        poolManager.file("vaultFactory", address(asyncVaultFactory), true);
        poolManager.file(
            "vaultFactory",
            address(syncDepositVaultFactory),
            true
        );

        asyncRequestManager.file("sender", address(messageDispatcher));
        asyncRequestManager.file("poolManager", address(poolManager));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        asyncRequestManager.file(
            "poolEscrowProvider",
            address(poolEscrowFactory)
        );

        syncRequestManager.file("poolManager", address(poolManager));
        syncRequestManager.file("balanceSheet", address(balanceSheet));
        syncRequestManager.file(
            "poolEscrowProvider",
            address(poolEscrowFactory)
        );

        balanceSheet.file("poolManager", address(poolManager));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

        poolEscrowFactory.file("poolManager", address(poolManager));
        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));
        poolEscrowFactory.file(
            "asyncRequestManager",
            address(asyncRequestManager)
        );
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
