// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Spoke} from "src/spoke/Spoke.sol";

import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer, SpokeCBD} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";

contract HooksCBD is SpokeCBD {
    // TODO: Add typed interfaces instead of addresses (only current reason is avoid test refactor)
    address public freezeOnlyHook;
    address public redemptionRestrictionsHook;
    address public fullRestrictionsHook;

    function deployHooks(CommonInput memory input, ICreateX createX, address deployer) public {
        deploySpoke(input, createX, deployer);

        freezeOnlyHook = createX.deployCreate3(
            generateSalt("freezeOnlyHook"),
            abi.encodePacked(type(FreezeOnly).creationCode, abi.encode(address(root), deployer))
        );

        fullRestrictionsHook = createX.deployCreate3(
            generateSalt("fullRestrictionsHook"),
            abi.encodePacked(type(FullRestrictions).creationCode, abi.encode(address(root), deployer))
        );

        redemptionRestrictionsHook = createX.deployCreate3(
            generateSalt("redemptionRestrictionsHook"),
            abi.encodePacked(type(RedemptionRestrictions).creationCode, abi.encode(address(root), deployer))
        );

        _hooksRely();
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

contract HooksDeployer is SpokeDeployer, HooksCBD {
    function deployHooks(CommonInput memory input, address deployer) public {
        super.deployHooks(input, _createX(), deployer);
    }

    function hooksRegister() internal {
        spokeRegister();
        register("freezeOnlyHook", address(freezeOnlyHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
    }
}
