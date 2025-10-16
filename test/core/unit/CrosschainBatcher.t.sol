// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {CrosschainBatcher} from "../../../src/core/messaging/CrosschainBatcher.sol";
import {IProtocolPauser} from "../../../src/core/messaging/interfaces/IProtocolPauser.sol";
import {ICrosschainBatcher} from "../../../src/core/messaging/interfaces/ICrosschainBatcher.sol";

import "forge-std/Test.sol";

contract GatewayExt is Gateway {
    constructor(uint16 centrifugeId_, IProtocolPauser pauser_, address deployer_)
        Gateway(centrifugeId_, pauser_, deployer_)
    {}

    function testTransientVariable(bytes memory data) external payable {
        this.startBatching();
        (bool success,) = msg.sender.call{value: msg.value}(data);
        require(success, "Call failed");
        this.endBatching(msg.sender);
    }
}

contract IntegrationMock is Test {
    bool public wasCalled;
    GatewayExt public gateway;
    CrosschainBatcher public batcher;
    uint256 public constant PAYMENT = 234;

    constructor(GatewayExt gateway_, CrosschainBatcher batcher_) {
        gateway = gateway_;
        batcher = batcher_;
    }

    function _nested() external {
        batcher.lockCallback();
        batcher.withBatch(abi.encodeWithSelector(this._success.selector, false, 2), address(0));
    }

    function _emptyError() external {
        batcher.lockCallback();
        revert();
    }

    function _notLocked() external {}

    function _success(bool, uint256) external {
        batcher.lockCallback();
        wasCalled = true;
    }

    function _justLock() external {
        batcher.lockCallback();
    }

    function _paid() external payable {
        assertEq(msg.value, PAYMENT);
        batcher.lockCallback();
    }

    function callNested(address refund) external {
        batcher.withBatch(abi.encodeWithSelector(this._nested.selector), refund);
    }

    function callEmptyError(address refund) external {
        batcher.withBatch(abi.encodeWithSelector(this._emptyError.selector), refund);
    }

    function callSuccess(address refund) external payable {
        batcher.withBatch{value: msg.value}(abi.encodeWithSelector(this._success.selector, true, 1), refund);
    }

    function callNotLocked(address refund) external {
        batcher.withBatch(abi.encodeWithSelector(this._notLocked.selector), refund);
    }

    function callPaid(address refund, uint256 value) external payable {
        batcher.withBatch{value: msg.value}(abi.encodeWithSelector(this._paid.selector), value, refund);
    }
}

contract AttackerIntegrationMock is Test {
    IntegrationMock prey;
    CrosschainBatcher batcher;

    constructor(CrosschainBatcher batcher_, IntegrationMock prey_) {
        batcher = batcher_;
        prey = prey_;
    }

    function callAttack(address refund) external {
        batcher.withBatch(abi.encodeWithSelector(this._attack.selector), refund);
    }

    function _attack() external payable {
        prey._justLock();
    }
}

contract CrosschainBatcherTest is Test {
    address constant ANY = address(0x42);
    address payable constant REFUND = payable(address(0x43));

    GatewayExt gateway;
    CrosschainBatcher batcher;
    IntegrationMock integration;
    AttackerIntegrationMock attacker;

    function setUp() public {
        IProtocolPauser pauser = IProtocolPauser(makeAddr("pauser"));
        vm.mockCall(address(pauser), abi.encodeWithSelector(IProtocolPauser.paused.selector), abi.encode(false));
        gateway = new GatewayExt(23, pauser, address(this));
        batcher = new CrosschainBatcher(gateway, address(this));

        vm.prank(address(this));
        gateway.rely(address(batcher));

        integration = new IntegrationMock(gateway, batcher);
        attacker = new AttackerIntegrationMock(batcher, integration);
    }

    function testErrCallFailedWithEmptyRevert() public {
        vm.prank(ANY);
        vm.expectRevert(ICrosschainBatcher.CallFailedWithEmptyRevert.selector);
        integration.callEmptyError(REFUND);
    }

    function testErrCallbackWasNotLocked() public {
        vm.prank(ANY);
        vm.expectRevert(ICrosschainBatcher.CallbackWasNotLocked.selector);
        integration.callNotLocked(REFUND);
    }

    function testErrCallbackNotFromSender() public {
        vm.prank(ANY);
        vm.expectRevert(ICrosschainBatcher.CallbackNotFromSender.selector);
        attacker.callAttack(REFUND);
    }

    function testErrNotEnoughValueForCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        vm.expectRevert(ICrosschainBatcher.NotEnoughValueForCallback.selector);
        integration.callPaid{value: 1234}(REFUND, 2000);
    }

    function testWithCallback() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callSuccess{value: 1234}(REFUND);

        assertEq(integration.wasCalled(), true);
        assertEq(REFUND.balance, 1234);
    }

    function testWithCallbackNested() public {
        vm.prank(ANY);
        integration.callNested(REFUND);

        assertEq(integration.wasCalled(), true);
    }

    function testWithCallbackPaid() public {
        vm.prank(ANY);
        vm.deal(ANY, 1234);
        integration.callPaid{value: 1234}(REFUND, integration.PAYMENT());

        assertEq(REFUND.balance, 1000);
        assertEq(address(integration).balance, integration.PAYMENT());
    }
}
