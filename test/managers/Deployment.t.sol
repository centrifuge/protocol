// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {ManagersDeployer} from "script/ManagersDeployer.s.sol";

import {CommonInput} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract ManagersDeploymentTest is ManagersDeployer, Test {
    function setUp() public {
        CommonInput memory input = CommonInput({
            centrifugeId: 23,
            adminSafe: ISafe(makeAddr("AdminSafe")),
            messageGasLimit: 0,
            maxBatchSize: 0,
            isTests: true
        });

        deployManagers(input, address(this));
        removeManagersDeployerAccess(address(this));
    }

    function testOnOfframpManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(onOfframpManagerFactory.spoke()), address(spoke));
        assertEq(address(onOfframpManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testMerkleProofManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(merkleProofManagerFactory.spoke()), address(spoke));
    }
}
