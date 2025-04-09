// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Auth, IAuth} from "src/misc/Auth.sol";
import {Recoverable} from "src/misc/Recoverable.sol";
import {ERC20} from "src/misc/ERC20.sol";

import "forge-std/Test.sol";
import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

contract RecoverableImpl is Recoverable {
    constructor(address deployer) Auth(deployer) {}
}

contract TestRecoverable is Test {
    uint256 constant AMOUNT = 100;
    uint256 constant TOKEN_ID = 23;
    address immutable RECEIVER = makeAddr("receiver");

    Recoverable recoverable = new RecoverableImpl(address(this));

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        recoverable.recoverTokens(address(0), address(0), 0);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        recoverable.recoverTokens(address(0), 0, address(0), 0);
    }

    function testRecoverTokensETH() public {
        address ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        vm.deal(address(recoverable), AMOUNT);

        recoverable.recoverTokens(ETH, 0, RECEIVER, AMOUNT);

        assertEq(address(recoverable).balance, 0);
        assertEq(RECEIVER.balance, AMOUNT);
    }

    function testRecoverTokensERC20() public {
        ERC20 token = new ERC20(18);
        token.mint(address(recoverable), AMOUNT);

        recoverable.recoverTokens(address(token), 0, RECEIVER, AMOUNT);

        assertEq(token.balanceOf(address(recoverable)), 0);
        assertEq(token.balanceOf(RECEIVER), AMOUNT);
    }

    function testRecoverTokensERC6909() public {
        MockERC6909 token = new MockERC6909();
        token.mint(address(recoverable), TOKEN_ID, AMOUNT);

        recoverable.recoverTokens(address(token), TOKEN_ID, RECEIVER, AMOUNT);

        assertEq(token.balanceOf(address(recoverable), TOKEN_ID), 0);
        assertEq(token.balanceOf(RECEIVER, TOKEN_ID), AMOUNT);
    }
}
