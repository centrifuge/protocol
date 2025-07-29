// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {VaultsActionBatcher} from "../../script/VaultsDeployer.s.sol";
import {HooksDeployer, HooksActionBatcher} from "../../script/HooksDeployer.s.sol";

contract VaultsDeploymentTest is HooksDeployer, CommonDeploymentInputTest {
    function setUp() public {
        VaultsActionBatcher vaultsBatcher = new VaultsActionBatcher();
        deployVaults(_commonInput(), vaultsBatcher);
        removeVaultsDeployerAccess(vaultsBatcher);

        HooksActionBatcher hooksBatcher = new HooksActionBatcher();
        deployHooks(_commonInput(), hooksBatcher);
        removeHooksDeployerAccess(hooksBatcher);
    }

    function testFreezeOnly(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(freezeOnlyHook).wards(address(root)), 1);
        assertEq(IAuth(freezeOnlyHook).wards(address(spoke)), 1);
        assertEq(IAuth(freezeOnlyHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freezeOnlyHook.root()), address(root));
    }

    function testRedemptionRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(redemptionRestrictionsHook.wards(address(root)), 1);
        assertEq(redemptionRestrictionsHook.wards(address(spoke)), 1);
        assertEq(redemptionRestrictionsHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(redemptionRestrictionsHook.root()), address(root));
    }

    function testFreelyTransferable(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(freelyTransferableHook).wards(address(root)), 1);
        assertEq(IAuth(freelyTransferableHook).wards(address(spoke)), 1);
        assertEq(IAuth(freelyTransferableHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freelyTransferableHook.root()), address(root));
    }

    function testFullRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(IAuth(fullRestrictionsHook).wards(address(root)), 1);
        assertEq(IAuth(fullRestrictionsHook).wards(address(spoke)), 1);
        assertEq(IAuth(fullRestrictionsHook).wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(fullRestrictionsHook.root()), address(root));
    }
}
