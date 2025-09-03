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

    function testIdentityValuation() public view {
        // dependencies set correctly
        assertEq(address(identityValuation.hubRegistry()), address(hubRegistry));
    }

    function testOracleValuation() public view {
        // dependencies set correctly
        assertEq(address(oracleValuation.hubRegistry()), address(hubRegistry));
    }
}
