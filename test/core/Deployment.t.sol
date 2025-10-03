// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {CommonDeployer, CommonInput, CommonActionBatcher} from "../../script/CommonDeployer.s.sol";

import "forge-std/Test.sol";

contract CommonDeploymentInputTest is Test {
    uint16 constant CENTRIFUGE_ID = 23;
    ISafe immutable ADMIN_SAFE = ISafe(makeAddr("AdminSafe"));
    ISafe immutable OPS_SAFE = ISafe(makeAddr("OpsSafe"));

    function _commonInput() internal view returns (CommonInput memory) {
        return CommonInput({centrifugeId: CENTRIFUGE_ID, adminSafe: ADMIN_SAFE, opsSafe: OPS_SAFE, version: bytes32(0)});
    }
}

contract CommonDeploymentTest is CommonDeployer, CommonDeploymentInputTest {
    function setUp() public virtual {
        CommonActionBatcher batcher = new CommonActionBatcher();
        deployCommon(_commonInput(), batcher);
        removeCommonDeployerAccess(batcher);
    }

    function testRoot(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(tokenRecoverer));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(root.wards(address(protocolGuardian)), 1);
        assertEq(root.wards(address(tokenRecoverer)), 1);
        assertEq(root.wards(address(messageProcessor)), 1);
        assertEq(root.wards(address(messageDispatcher)), 1);
        assertEq(root.wards(nonWard), 0);
    }

    function testProtocolGuardian() public view {
        // dependencies set correctly
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.safe()), address(ADMIN_SAFE));
        assertEq(address(protocolGuardian.gateway()), address(gateway));
        assertEq(address(protocolGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(protocolGuardian.sender()), address(messageDispatcher));
    }

    function testOpsGuardian() public view {
        // dependencies set correctly
        assertEq(address(opsGuardian.opsSafe()), address(OPS_SAFE));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
    }

    function testTokenRecoverer(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(tokenRecoverer.wards(address(root)), 1);
        assertEq(tokenRecoverer.wards(address(protocolGuardian)), 1);
        assertEq(tokenRecoverer.wards(address(messageProcessor)), 1);
        assertEq(tokenRecoverer.wards(address(messageDispatcher)), 1);
        assertEq(tokenRecoverer.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(tokenRecoverer.root()), address(root));
    }

    function testMessageProcessor(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(gateway));

        assertEq(messageProcessor.wards(address(root)), 1);
        assertEq(messageProcessor.wards(address(gateway)), 1);
        assertEq(messageProcessor.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(messageProcessor.root()), address(root));
        assertEq(address(messageProcessor.tokenRecoverer()), address(tokenRecoverer));
        assertEq(address(messageProcessor.multiAdapter()), address(multiAdapter));
        assertEq(address(messageProcessor.gateway()), address(gateway));
    }

    function testMessageDispatcher(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));

        assertEq(messageDispatcher.wards(address(root)), 1);
        assertEq(messageDispatcher.wards(address(protocolGuardian)), 1);
        assertEq(messageDispatcher.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(messageDispatcher.root()), address(root));
        assertEq(address(messageDispatcher.tokenRecoverer()), address(tokenRecoverer));
        assertEq(address(messageDispatcher.gateway()), address(gateway));
        assertEq(messageDispatcher.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testGasService() public pure {
        // Nothing to check
    }

    function testGateway(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(multiAdapter));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(messageProcessor));

        assertEq(gateway.wards(address(root)), 1);
        assertEq(gateway.wards(address(protocolGuardian)), 1);
        assertEq(gateway.wards(address(multiAdapter)), 1);
        assertEq(gateway.wards(address(messageDispatcher)), 1);
        assertEq(gateway.wards(address(messageProcessor)), 1);
        assertEq(gateway.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(gateway.processor()), address(messageProcessor));
        assertEq(address(gateway.adapter()), address(multiAdapter));
        assertEq(address(gateway.messageLimits()), address(gasService));
        assertEq(gateway.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testMultiAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(gateway));
        vm.assume(nonWard != address(messageProcessor));

        assertEq(multiAdapter.wards(address(root)), 1);
        assertEq(multiAdapter.wards(address(protocolGuardian)), 1);
        assertEq(multiAdapter.wards(address(opsGuardian)), 1);
        assertEq(multiAdapter.wards(address(gateway)), 1);
        assertEq(multiAdapter.wards(address(messageProcessor)), 1);
        assertEq(multiAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(multiAdapter.gateway()), address(gateway));
        assertEq(address(multiAdapter.messageProperties()), address(messageProcessor));
        assertEq(multiAdapter.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testPoolEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));

        assertEq(poolEscrowFactory.wards(address(root)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.root()), address(root));
        assertEq(address(poolEscrowFactory.gateway()), address(gateway));
    }
}
