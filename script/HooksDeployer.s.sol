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

contract HooksDeployer is SpokeDeployer {
    // TODO: Add typed interfaces instead of addresses (only current reason is avoid test refactor)
    address public freezeOnlyHook;
    address public redemptionRestrictionsHook;
    address public fullRestrictionsHook;

    function deployHooks(CommonInput memory input, address deployer) public {
        deploySpoke(input, deployer);

        freezeOnlyHook = create3(
            generateSalt("freezeOnlyHook"),
            abi.encodePacked(type(FreezeOnly).creationCode, abi.encode(address(root), deployer))
        );

        fullRestrictionsHook = create3(
            generateSalt("fullRestrictionsHook"),
            abi.encodePacked(type(FullRestrictions).creationCode, abi.encode(address(root), deployer))
        );

        redemptionRestrictionsHook = create3(
            generateSalt("redemptionRestrictionsHook"),
            abi.encodePacked(type(RedemptionRestrictions).creationCode, abi.encode(address(root), deployer))
        );

        _hooksRegister();
        _hooksRely();
    }

    function _hooksRegister() private {
        register("freezeOnlyHook", address(freezeOnlyHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
    }

    function _hooksRely() private {
        // Rely Spoke
        IAuth(freezeOnlyHook).rely(address(spoke));
        IAuth(fullRestrictionsHook).rely(address(spoke));
        IAuth(redemptionRestrictionsHook).rely(address(spoke));

        // Rely Root
        IAuth(freezeOnlyHook).rely(address(root));
        IAuth(fullRestrictionsHook).rely(address(root));
        IAuth(redemptionRestrictionsHook).rely(address(root));
    }

    function removeHooksDeployerAccess(address deployer) public {
        removeSpokeDeployerAccess(deployer);

        IAuth(freezeOnlyHook).deny(deployer);
        IAuth(fullRestrictionsHook).deny(deployer);
        IAuth(redemptionRestrictionsHook).deny(deployer);
    }
}
