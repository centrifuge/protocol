pragma solidity 0.8.26;
// SPDX-License-Identifier: AGPL-3.0-only

import {Guardian} from "src/admin/Guardian.sol";
import "test/BaseTest.sol";

contract GuardianTest is BaseTest {
    function testGuardian() public {
        Guardian guardian = new Guardian(address(adminSafe), address(root), address(gateway));
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.gateway()), address(gateway));
    }
}
