// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Spoke} from "src/spoke/Spoke.sol";

import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";

struct HooksReport {
    SpokeReport spoke;
    address freezeOnlyHook;
    address redemptionRestrictionsHook;
    address fullRestrictionsHook;
}

contract HooksActionBatcher is SpokeActionBatcher {
    function engageHooks(HooksReport memory report) public unlocked {
        // Rely Spoke
        IAuth(report.freezeOnlyHook).rely(address(report.spoke.spoke));
        IAuth(report.fullRestrictionsHook).rely(address(report.spoke.spoke));
        IAuth(report.redemptionRestrictionsHook).rely(address(report.spoke.spoke));

        // Rely Root
        IAuth(report.freezeOnlyHook).rely(address(report.spoke.common.root));
        IAuth(report.fullRestrictionsHook).rely(address(report.spoke.common.root));
        IAuth(report.redemptionRestrictionsHook).rely(address(report.spoke.common.root));
    }

    function revokeHooks(HooksReport memory report) public unlocked {
        IAuth(report.freezeOnlyHook).deny(address(this));
        IAuth(report.fullRestrictionsHook).deny(address(this));
        IAuth(report.redemptionRestrictionsHook).deny(address(this));
    }
}

contract HooksDeployer is SpokeDeployer {
    // TODO: Add typed interfaces instead of addresses (only current reason is avoid test refactor)
    address public freezeOnlyHook;
    address public redemptionRestrictionsHook;
    address public fullRestrictionsHook;

    function deployHooks(CommonInput memory input, HooksActionBatcher batcher) public {
        preDeployHooks(input, batcher);
        postDeployHooks(batcher);
    }

    function preDeployHooks(CommonInput memory input, HooksActionBatcher batcher) internal {
        preDeploySpoke(input, batcher);

        freezeOnlyHook = create3(
            generateSalt("freezeOnlyHook"),
            abi.encodePacked(type(FreezeOnly).creationCode, abi.encode(address(root), batcher))
        );

        fullRestrictionsHook = create3(
            generateSalt("fullRestrictionsHook"),
            abi.encodePacked(type(FullRestrictions).creationCode, abi.encode(address(root), batcher))
        );

        redemptionRestrictionsHook = create3(
            generateSalt("redemptionRestrictionsHook"),
            abi.encodePacked(type(RedemptionRestrictions).creationCode, abi.encode(address(root), batcher))
        );

        batcher.engageHooks(_hooksReport());

        register("freezeOnlyHook", address(freezeOnlyHook));
        register("redemptionRestrictionsHook", address(redemptionRestrictionsHook));
        register("fullRestrictionsHook", address(fullRestrictionsHook));
    }

    function postDeployHooks(HooksActionBatcher batcher) internal {
        postDeploySpoke(batcher);
    }

    function removeHooksDeployerAccess(HooksActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);

        batcher.revokeHooks(_hooksReport());
    }

    function _hooksReport() internal view returns (HooksReport memory) {
        return HooksReport(_spokeReport(), freezeOnlyHook, redemptionRestrictionsHook, fullRestrictionsHook);
    }
}
