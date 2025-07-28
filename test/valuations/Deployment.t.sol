// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {ValuationsDeployer, ValuationsActionBatcher} from "../../script/ValuationsDeployer.s.sol";

import "forge-std/Test.sol";

contract ValuationsDeploymentTest is ValuationsDeployer, CommonDeploymentInputTest {
    function setUp() public {
        ValuationsActionBatcher batcher = new ValuationsActionBatcher();
        deployValuations(_commonInput(), batcher);
        removeValuationsDeployerAccess(batcher);
    }

    function testIdentityValuation(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));

        assertEq(identityValuation.wards(address(root)), 1);
        assertEq(identityValuation.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(identityValuation.erc6909()), address(hubRegistry));
    }
}
