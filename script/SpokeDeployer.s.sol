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

import {CommonDeployer, CommonInput} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

contract SpokeDeployer is CommonDeployer {
    Spoke public spoke;
    BalanceSheet public balanceSheet;
    TokenFactory public tokenFactory;

    function deploySpoke(CommonInput memory input, address deployer) public {
        if (address(spoke) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        deployCommon(input, deployer);

        tokenFactory = TokenFactory(
            create3(
                generateSalt("tokenFactory"),
                abi.encodePacked(type(TokenFactory).creationCode, abi.encode(address(root), deployer))
            )
        );

        spoke = Spoke(
            create3(
                generateSalt("spoke"), abi.encodePacked(type(Spoke).creationCode, abi.encode(tokenFactory, deployer))
            )
        );

        balanceSheet = BalanceSheet(
            create3(
                generateSalt("balanceSheet"),
                abi.encodePacked(type(BalanceSheet).creationCode, abi.encode(root, deployer))
            )
        );

        _spokeRegister();
        _spokeEndorse();
        _spokeRely();
        _spokeFile();
    }

    function _spokeRegister() private {
        register("tokenFactory", address(tokenFactory));
        register("spoke", address(spoke));
        register("balanceSheet", address(balanceSheet));
    }

    function _spokeEndorse() private {
        root.endorse(address(balanceSheet));
    }

    function _spokeRely() private {
        // Rely Spoke
        tokenFactory.rely(address(spoke));
        messageDispatcher.rely(address(spoke));
        poolEscrowFactory.rely(address(spoke));
        gateway.rely(address(spoke));

        // Rely BalanceSheet
        messageDispatcher.rely(address(balanceSheet));
        gateway.rely(address(balanceSheet));

        // Rely Root
        spoke.rely(address(root));
        balanceSheet.rely(address(root));
        tokenFactory.rely(address(root));

        // Rely messageProcessor
        spoke.rely(address(messageProcessor));
        balanceSheet.rely(address(messageProcessor));

        // Rely messageDispatcher
        spoke.rely(address(messageDispatcher));
        balanceSheet.rely(address(messageDispatcher));
    }

    function _spokeFile() public {
        messageDispatcher.file("spoke", address(spoke));
        messageDispatcher.file("balanceSheet", address(balanceSheet));

        messageProcessor.file("spoke", address(spoke));
        messageProcessor.file("balanceSheet", address(balanceSheet));

        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(messageDispatcher));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

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
        if (spoke.wards(deployer) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        removeCommonDeployerAccess(deployer);

        tokenFactory.deny(deployer);
        spoke.deny(deployer);
        balanceSheet.deny(deployer);
    }
}
