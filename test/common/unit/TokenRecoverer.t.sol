// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../../src/misc/Auth.sol";
import {IRecoverable} from "../../../src/misc/interfaces/IRecoverable.sol";

import {IRoot} from "../../../src/common/interfaces/IRoot.sol";
import {TokenRecoverer, ITokenRecoverer} from "../../../src/common/TokenRecoverer.sol";

import "forge-std/Test.sol";

contract TestTokenRecoverer is Test {
    uint256 constant AMOUNT = 100;
    uint256 constant TOKEN_ID = 23;
    address immutable TOKEN = makeAddr("erc20");
    address immutable RECEIVER = makeAddr("receiver");
    IRoot immutable ROOT = IRoot(makeAddr("root"));
    IRecoverable immutable RECOVERABLE = IRecoverable(makeAddr("recoverable"));

    TokenRecoverer tokenRecoverer = new TokenRecoverer(ROOT, address(this));

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        tokenRecoverer.recoverTokens(RECOVERABLE, address(0), 0, address(0), 0);
    }

    function testSuccess() public {
        // We need to compute the selector directly to avoid collition
        bytes4 recoverTokensSelector = bytes4(keccak256("recoverTokens(address,uint256,address,uint256)"));

        vm.mockCall(
            address(ROOT),
            abi.encodeWithSelector(IRoot.relyContract.selector, RECOVERABLE, address(tokenRecoverer)),
            abi.encode(0)
        );
        vm.mockCall(
            address(RECOVERABLE),
            abi.encodeWithSelector(recoverTokensSelector, TOKEN, TOKEN_ID, RECEIVER, AMOUNT),
            abi.encode(0)
        );
        vm.mockCall(
            address(ROOT),
            abi.encodeWithSelector(IRoot.denyContract.selector, RECOVERABLE, address(tokenRecoverer)),
            abi.encode(0)
        );

        emit ITokenRecoverer.RecoverTokens(RECOVERABLE, TOKEN, TOKEN_ID, RECEIVER, AMOUNT);
        tokenRecoverer.recoverTokens(RECOVERABLE, TOKEN, TOKEN_ID, RECEIVER, AMOUNT);
    }
}
