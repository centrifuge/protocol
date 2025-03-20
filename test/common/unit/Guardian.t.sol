// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Guardian, ISafe, IRoot} from "src/common/Guardian.sol";

import "forge-std/Test.sol";

contract GuardianTest is Test {
    ISafe immutable adminSafe = ISafe(makeAddr("adminSafe"));
    IRoot immutable root = IRoot(makeAddr("adminSafe"));

    function testGuardian() public {
        Guardian guardian = new Guardian(adminSafe, root);
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.root()), address(root));
    }
}
