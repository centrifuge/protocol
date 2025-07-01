// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {FreezeOnly} from "src/hooks/FreezeOnly.sol";

import {HooksDeployer, HooksActionBatcher} from "script/HooksDeployer.s.sol";

import {CommonDeploymentInputTest} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract VaultsDeploymentTest is HooksDeployer, CommonDeploymentInputTest {
    function setUp() public {
        HooksActionBatcher batcher = new HooksActionBatcher();
        deployHooks(_commonInput(), batcher);
        removeHooksDeployerAccess(batcher);
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
