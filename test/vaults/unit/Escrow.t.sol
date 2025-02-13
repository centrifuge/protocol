pragma solidity 0.8.26;
// SPDX-License-Identifier: AGPL-3.0-only

import {Escrow} from "src/Escrow.sol";
import "test/BaseTest.sol";

contract EscrowTest is BaseTest {
    function testApproveMax() public {
        Escrow escrow = new Escrow(address(this));
        address spender = address(0x2);
        assertEq(erc20.allowance(address(escrow), spender), 0);

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.approveMax(address(erc20), spender);

        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);
    }

    function testUnapprove() public {
        Escrow escrow = new Escrow(address(this));
        address spender = address(0x2);
        escrow.approveMax(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), type(uint256).max);

        vm.prank(randomUser);
        vm.expectRevert("Auth/not-authorized");
        escrow.unapprove(address(erc20), spender);

        escrow.unapprove(address(erc20), spender);
        assertEq(erc20.allowance(address(escrow), spender), 0);
    }
}
