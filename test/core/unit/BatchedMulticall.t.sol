// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGateway} from "../../../src/core/messaging/interfaces/IGateway.sol";
import {BatchedMulticall} from "../../../src/core/utils/BatchedMulticall.sol";

import "forge-std/Test.sol";

contract BatchedMulticallImpl is BatchedMulticall, Test {
    uint256 public total;
    address public lastSender;

    constructor(IGateway gateway) BatchedMulticall(gateway) {}

    function nonZeroPayment() external payable {
        assertNotEq(msgValue(), 0);
    }

    function add(uint256 i) external payable {
        assertEq(msgValue(), 0);
        total += i;
    }

    function recordSender() external {
        lastSender = msgSender();
    }

    function nestedCall(bytes[] calldata data) external {
        // This performs a nested multicall
        this.multicall(data);
    }

    // Public getter for msgSender (for testing purposes)
    function getCurrentSender() external view returns (address) {
        return msgSender();
    }

    // Call an external contract (for reentrancy testing)
    function callExternal(address target, bytes calldata data) external {
        (bool success,) = target.call(data);
        require(success, "external call failed");
    }
}

contract MockGateway {
    address internal transient _batcher;

    function withBatch(bytes memory data, address) external payable {
        _batcher = msg.sender;
        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "call-failed-empty-revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
    }

    function lockCallback() external returns (address caller) {
        caller = _batcher;
        _batcher = address(0);
    }
}

/// @dev Malicious contract that performs reentrancy to impersonate the original caller
contract MaliciousReentrancy {
    BatchedMulticallImpl public target;
    address public stolenSender;
    bool public hasReentered;

    constructor(BatchedMulticallImpl _target) {
        target = _target;
    }

    /// @dev This function is called during the first multicall
    /// It re-enters multicall() while _sender is still set to the victim's address
    function attack() external {
        if (!hasReentered) {
            hasReentered = true;

            // Re-enter multicall while _sender is still set to the original caller
            // This allows us to steal their identity by calling recordSender on the target
            bytes[] memory maliciousCalls = new bytes[](1);
            maliciousCalls[0] = abi.encodeWithSelector(target.recordSender.selector);

            target.multicall(maliciousCalls);

            // After the reentrancy, read the stolen sender from the target
            stolenSender = target.lastSender();
        }
    }
}

contract BatchedMulticallTest is Test {
    IGateway immutable gateway = IGateway(address(new MockGateway()));
    BatchedMulticallImpl multicall = new BatchedMulticallImpl(gateway);

    function setUp() external {}
}

contract BatchedMulticallTestMulticall is BatchedMulticallTest {
    function _foo() external {}

    function testPaymentIsNonZeroWithoutMulticall() external {
        multicall.nonZeroPayment{value: 1}();
    }

    function testMulticallTest() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(multicall.add.selector, 2);
        calls[1] = abi.encodeWithSelector(multicall.add.selector, 3);

        multicall.multicall{value: 1}(calls);

        assertEq(multicall.total(), 5);
    }

    function testNestedMulticall() external {
        // Create inner multicall that records the sender
        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(multicall.recordSender.selector);

        // Create outer multicall that includes a nested multicall encoded in the data
        // This is the CORRECT pattern - encoding multicall as call data, which executes through gateway
        bytes[] memory outerCalls = new bytes[](1);
        outerCalls[0] = abi.encodeWithSelector(multicall.multicall.selector, innerCalls);

        // Execute the nested multicall
        multicall.multicall{value: 1}(outerCalls);

        // Expected: msgSender() inside recordSender should be address(this) (the test contract)
        assertEq(multicall.lastSender(), address(this), "msgSender should be preserved in nested multicall");
    }

    function testReentrancyBlocked() external {
        // Deploy malicious contract
        MaliciousReentrancy attacker = new MaliciousReentrancy(multicall);

        // Victim is the test contract (address(this))
        address victim = address(this);

        console2.log("Victim address:", victim);
        console2.log("Attacker address:", address(attacker));

        // Victim calls multicall with a call that triggers the attacker
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            multicall.callExternal.selector, address(attacker), abi.encodeWithSelector(attacker.attack.selector)
        );

        // The attacker's reentrancy attempt should be blocked
        // The require(!isNested || msg.sender == address(gateway)) protection
        // prevents the malicious nested multicall because:
        // 1. When attacker calls target.multicall(), _sender is still set (transient storage persists)
        // 2. So isNested = true
        // 3. But msg.sender is the attacker contract, not the gateway
        // 4. The require fails, blocking the reentrancy attack

        // This call should revert with "external call failed" because the inner attack fails
        vm.expectRevert("external call failed");
        multicall.multicall{value: 1}(calls);

        // If we reach here, the test passed - reentrancy was successfully blocked
        console2.log("SUCCESS: Reentrancy attack was blocked by the protection!");
    }
}
