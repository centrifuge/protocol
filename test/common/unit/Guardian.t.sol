// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Guardian, ISafe, IRoot, IRootMessageSender} from "src/common/Guardian.sol";

import "forge-std/Test.sol";

contract GuardianTest is Test {
    ISafe immutable adminSafe = ISafe(makeAddr("adminSafe"));
    IRoot immutable root = IRoot(makeAddr("root"));
    IRootMessageSender messageDispatcher = IRootMessageSender(makeAddr("messageDispatcher"));

    function testGuardian() public {
        Guardian guardian = new Guardian(adminSafe, root, messageDispatcher);
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.sender()), address(messageDispatcher));
    }
}
