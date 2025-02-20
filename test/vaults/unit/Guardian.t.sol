// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Guardian} from "src/vaults/admin/Guardian.sol";
import "test/vaults/BaseTest.sol";

contract GuardianTest is BaseTest {
    function testGuardian() public {
        Guardian guardian = new Guardian(address(adminSafe), address(root), address(gateway));
        assertEq(address(guardian.safe()), address(adminSafe));
        assertEq(address(guardian.root()), address(root));
        assertEq(address(guardian.gateway()), address(gateway));
    }
}
