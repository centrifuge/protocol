// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {FreezeOnly} from "src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "src/hooks/RedemptionRestrictions.sol";

import {HooksDeployer} from "script/HooksDeployer.s.sol";

import {CommonInput} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract VaultsDeploymentTest is HooksDeployer, Test {
    function setUp() public {
        CommonInput memory input = CommonInput({
            centrifugeId: 23,
            adminSafe: ISafe(makeAddr("AdminSafe")),
            messageGasLimit: 0,
            maxBatchSize: 0,
            isTests: true
        });

        deployHooks(input, address(this));
        removeHooksDeployerAccess(address(this));
    }

    function testFreezeOnly(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(freezeOnlyHook).wards(address(root)), 1);
        assertEq(IAuth(freezeOnlyHook).wards(address(spoke)), 1);
        assertEq(IAuth(freezeOnlyHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(FreezeOnly(freezeOnlyHook).root()), address(root));
    }

    function testRedemptionRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(redemptionRestrictionsHook).wards(address(root)), 1);
        assertEq(IAuth(redemptionRestrictionsHook).wards(address(spoke)), 1);
        assertEq(IAuth(redemptionRestrictionsHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(FreezeOnly(redemptionRestrictionsHook).root()), address(root));
    }

    function testFullRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(fullRestrictionsHook).wards(address(root)), 1);
        assertEq(IAuth(fullRestrictionsHook).wards(address(spoke)), 1);
        assertEq(IAuth(fullRestrictionsHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(FreezeOnly(fullRestrictionsHook).root()), address(root));
    }
}
