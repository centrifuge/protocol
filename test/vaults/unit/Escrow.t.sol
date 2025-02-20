// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Escrow} from "src/vaults/Escrow.sol";
import "test/vaults/BaseTest.sol";

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
