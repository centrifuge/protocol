// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "../../src/common/interfaces/IGuardian.sol";

import {CommonDeployer, CommonInput, CommonActionBatcher} from "../../script/CommonDeployer.s.sol";

import "forge-std/Test.sol";

contract CommonDeploymentInputTest is Test {
    uint16 constant CENTRIFUGE_ID = 23;
    ISafe immutable ADMIN_SAFE = ISafe(makeAddr("AdminSafe"));

    function _commonInput() internal view returns (CommonInput memory) {
        return
            CommonInput({centrifugeId: CENTRIFUGE_ID, adminSafe: ADMIN_SAFE, maxBatchGasLimit: 0, version: bytes32(0)});
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
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(tokenRecoverer));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(root.wards(address(guardian)), 1);
        assertEq(root.wards(address(tokenRecoverer)), 1);
        assertEq(root.wards(address(messageProcessor)), 1);
        assertEq(root.wards(address(messageDispatcher)), 1);
        assertEq(root.wards(nonWard), 0);
    }

    function testGuardian() public view {
        // dependencies set correctly
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.safe()), address(ADMIN_SAFE));
        assertEq(address(guardian.multiAdapter()), address(multiAdapter));
        assertEq(address(guardian.sender()), address(messageDispatcher));
    }

    function testTokenRecoverer(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(tokenRecoverer.wards(address(root)), 1);
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
    }

    function testMessageDispatcher(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));

        assertEq(messageDispatcher.wards(address(root)), 1);
        assertEq(messageDispatcher.wards(address(guardian)), 1);
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
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(multiAdapter));

        assertEq(gateway.wards(address(root)), 1);
        assertEq(gateway.wards(address(messageDispatcher)), 1);
        assertEq(gateway.wards(address(multiAdapter)), 1);
        assertEq(gateway.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(gateway.root()), address(root));
        assertEq(address(gateway.gasService()), address(gasService));
        assertEq(address(gateway.processor()), address(messageProcessor));
        assertEq(address(gateway.adapter()), address(multiAdapter));
    }

    function testMultiAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(gateway));

        assertEq(multiAdapter.wards(address(root)), 1);
        assertEq(multiAdapter.wards(address(guardian)), 1);
        assertEq(multiAdapter.wards(address(gateway)), 1);
        assertEq(multiAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(multiAdapter.gateway()), address(gateway));
        assertEq(multiAdapter.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testPoolEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));

        assertEq(poolEscrowFactory.wards(address(root)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.root()), address(root));
        assertEq(address(poolEscrowFactory.gateway()), address(gateway));
    }
}
