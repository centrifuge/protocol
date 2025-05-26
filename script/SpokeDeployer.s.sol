// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/Guardian.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Create3Factory} from "src/common/Create3Factory.sol";

import {AsyncRequestManager} from "src/spoke/vaults/AsyncRequestManager.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {AsyncVaultFactory} from "src/spoke/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/spoke/factories/SyncDepositVaultFactory.sol";
import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {SyncRequestManager} from "src/spoke/vaults/SyncRequestManager.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {VaultRouter} from "src/spoke/vaults/VaultRouter.sol";
import {Escrow} from "src/spoke/Escrow.sol";
import {IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {PoolEscrowFactory} from "src/spoke/factories/PoolEscrowFactory.sol";
import {IVaultFactory} from "src/spoke/interfaces/factories/IVaultFactory.sol";

import "forge-std/Script.sol";
import {CommonDeployer} from "script/CommonDeployer.s.sol";

contract SpokeDeployer is CommonDeployer {
    BalanceSheet public balanceSheet;
    AsyncRequestManager public asyncRequestManager;
    SyncRequestManager public syncRequestManager;
    Spoke public spoke;
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

    function deploySpoke(
        uint16 centrifugeId,
        ISafe adminSafe_,
        address deployer,
        bool isTests
    ) public {
        deployCommon(centrifugeId, adminSafe_, deployer, isTests);

        Create3Factory create3Factory = Create3Factory(
            0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf
        );

        poolEscrowFactory = PoolEscrowFactory(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("pool-escrow-factory")),
                    abi.encodePacked(
                        type(PoolEscrowFactory).creationCode,
                        abi.encode(address(root), deployer)
                    )
                )
            )
        );

        routerEscrow = Escrow(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("router-escrow")),
                    abi.encodePacked(
                        type(Escrow).creationCode,
                        abi.encode(deployer)
                    )
                )
            )
        );

        globalEscrow = Escrow(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("global-escrow")),
                    abi.encodePacked(
                        type(Escrow).creationCode,
                        abi.encode(deployer)
                    )
                )
            )
        );

        tokenFactory = TokenFactory(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("token-factory")),
                    abi.encodePacked(
                        type(TokenFactory).creationCode,
                        abi.encode(address(root), deployer)
                    )
                )
            )
        );

        asyncRequestManager = AsyncRequestManager(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("async-request-manager")),
                    abi.encodePacked(
                        type(AsyncRequestManager).creationCode,
                        abi.encode(
                            IEscrow(globalEscrow),
                            address(root),
                            deployer
                        )
                    )
                )
            )
        );

        syncRequestManager = SyncRequestManager(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("sync-request-manager")),
                    abi.encodePacked(
                        type(SyncRequestManager).creationCode,
                        abi.encode(
                            IEscrow(globalEscrow),
                            address(root),
                            deployer
                        )
                    )
                )
            )
        );

        asyncVaultFactory = AsyncVaultFactory(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("async-vault-factory")),
                    abi.encodePacked(
                        type(AsyncVaultFactory).creationCode,
                        abi.encode(address(root), asyncRequestManager, deployer)
                    )
                )
            )
        );

        syncDepositVaultFactory = SyncDepositVaultFactory(
            payable(
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
            )
        );

        spoke = Spoke(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("spoke")),
                    abi.encodePacked(
                        type(Spoke).creationCode,
                        abi.encode(tokenFactory, deployer)
                    )
                )
            )
        );

        balanceSheet = BalanceSheet(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("balance-sheet")),
                    abi.encodePacked(
                        type(BalanceSheet).creationCode,
                        abi.encode(root, deployer)
                    )
                )
            )
        );

        vaultRouter = VaultRouter(
            payable(
                create3Factory.deploy(
                    keccak256(abi.encodePacked("vault-router")),
                    abi.encodePacked(
                        type(VaultRouter).creationCode,
                        abi.encode(
                            address(routerEscrow),
                            gateway,
                            spoke,
                            messageDispatcher,
                            deployer
                        )
                    )
                )
            )
        );

        // Hooks
        freezeOnlyHook = address(
            FreezeOnly(
                payable(
                    create3Factory.deploy(
                        keccak256(abi.encodePacked("freeze-only-hook")),
                        abi.encodePacked(
                            type(FreezeOnly).creationCode,
                            abi.encode(address(root), deployer)
                        )
                    )
                )
            )
        );

        fullRestrictionsHook = address(
            FullRestrictions(
                payable(
                    create3Factory.deploy(
                        keccak256(abi.encodePacked("full-restrictions-hook")),
                        abi.encodePacked(
                            type(FullRestrictions).creationCode,
                            abi.encode(address(root), deployer)
                        )
                    )
                )
            )
        );

        redemptionRestrictionsHook = address(
            RedemptionRestrictions(
                payable(
                    create3Factory.deploy(
                        keccak256(
                            abi.encodePacked("redemption-restrictions-hook")
                        ),
                        abi.encodePacked(
                            type(RedemptionRestrictions).creationCode,
                            abi.encode(address(root), deployer)
                        )
                    )
                )
            )
        );

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
        asyncRequestManager.rely(address(gateway));
        spoke.rely(address(gateway));

        // Rely others
        routerEscrow.rely(address(vaultRouter));
        syncRequestManager.rely(address(syncDepositVaultFactory));

        // Rely messageProcessor
        spoke.rely(address(messageProcessor));
        asyncRequestManager.rely(address(messageProcessor));
        balanceSheet.rely(address(messageProcessor));

        // Rely messageDispatcher
        spoke.rely(address(messageDispatcher));
        asyncRequestManager.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));

        // Rely VaultRouter
        gateway.rely(address(vaultRouter));
        spoke.rely(address(vaultRouter));
    }

    function _spokeFile() public {
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file(
            "investmentManager",
            address(asyncRequestManager)
        );
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("spoke", address(spoke));
        messageProcessor.file(
            "investmentManager",
            address(asyncRequestManager)
        );
        messageProcessor.file("balanceSheet", address(balanceSheet));

        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));
        spoke.file("vaultFactory", address(asyncVaultFactory), true);
        spoke.file("vaultFactory", address(syncDepositVaultFactory), true);

        asyncRequestManager.file("sender", address(messageDispatcher));
        asyncRequestManager.file("spoke", address(spoke));
        asyncRequestManager.file("balanceSheet", address(balanceSheet));
        asyncRequestManager.file(
            "poolEscrowProvider",
            address(poolEscrowFactory)
        );

        syncRequestManager.file("spoke", address(spoke));
        syncRequestManager.file("balanceSheet", address(balanceSheet));
        syncRequestManager.file(
            "poolEscrowProvider",
            address(poolEscrowFactory)
        );

        balanceSheet.file("spoke", address(spoke));
        balanceSheet.file("sender", address(messageDispatcher));
        balanceSheet.file("poolEscrowProvider", address(poolEscrowFactory));

        poolEscrowFactory.file("spoke", address(spoke));
        poolEscrowFactory.file("gateway", address(gateway));
        poolEscrowFactory.file("balanceSheet", address(balanceSheet));
        poolEscrowFactory.file(
            "asyncRequestManager",
            address(asyncRequestManager)
        );

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
