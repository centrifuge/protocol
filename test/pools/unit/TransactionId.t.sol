// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";
import {ITransactionId} from "src/pools/interfaces/ITransactionId.sol";
import {TransactionId} from "src/pools/TransactionId.sol";

PoolId constant POOL_A = PoolId.wrap(1);
PoolId constant POOL_B = PoolId.wrap(2);

contract TransactionIdTest is Test {
    TransactionId transactionId = new TransactionId(address(this));

    function testTransactionId() public {
        bytes32 txId = transactionId.generateTransactionId(POOL_A);
        assertEq(txId, bytes32(uint256(1)));
        assertEq(transactionId.transactionId(), bytes32(uint256(1)));

        bytes32 txId2 = transactionId.generateTransactionId(POOL_A);
        assertEq(txId2, bytes32(uint256(2)));
        assertEq(transactionId.transactionId(), bytes32(uint256(2)));

        transactionId.generateTransactionId(POOL_B);
        assertEq(transactionId.transactionId(), bytes32(uint256(1)));
    }

    function testAuth() public {
        vm.prank(makeAddr("randomUser"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        transactionId.generateTransactionId(POOL_A);
    }
}
