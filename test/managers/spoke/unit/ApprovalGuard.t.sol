// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ApprovalGuard} from "../../../../src/managers/spoke/ApprovalGuard.sol";
import {IApprovalGuard, ApprovalEntry} from "../../../../src/managers/spoke/interfaces/IApprovalGuard.sol";

import "forge-std/Test.sol";

// ─── Mock ERC20 with controllable allowance ──────────────────────────────────

contract MockERC20 {
    mapping(address => mapping(address => uint256)) public allowance;

    function setAllowance(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

contract ApprovalGuardTest is Test {
    ApprovalGuard guard;
    MockERC20 tokenA;
    MockERC20 tokenB;
    address spenderA = makeAddr("spenderA");
    address spenderB = makeAddr("spenderB");

    function setUp() public {
        guard = new ApprovalGuard();
        tokenA = new MockERC20();
        tokenB = new MockERC20();
    }

    function testZeroAllowancesPass() public view {
        ApprovalEntry[] memory entries = new ApprovalEntry[](2);
        entries[0] = ApprovalEntry(address(tokenA), spenderA);
        entries[1] = ApprovalEntry(address(tokenB), spenderB);

        guard.checkZeroAllowances(entries);
    }

    function testEmptyEntriesPass() public view {
        ApprovalEntry[] memory entries = new ApprovalEntry[](0);
        guard.checkZeroAllowances(entries);
    }

    function testNonZeroAllowanceReverts() public {
        // Set a dangling allowance from this contract (the caller) to spenderA
        tokenA.setAllowance(address(this), spenderA, 100);

        ApprovalEntry[] memory entries = new ApprovalEntry[](1);
        entries[0] = ApprovalEntry(address(tokenA), spenderA);

        vm.expectRevert(
            abi.encodeWithSelector(IApprovalGuard.NonZeroAllowance.selector, address(tokenA), spenderA, 100)
        );
        guard.checkZeroAllowances(entries);
    }

    function testMixedAllowancesReverts() public {
        // tokenA allowance is zero, tokenB has a dangling allowance
        tokenB.setAllowance(address(this), spenderB, 50);

        ApprovalEntry[] memory entries = new ApprovalEntry[](2);
        entries[0] = ApprovalEntry(address(tokenA), spenderA);
        entries[1] = ApprovalEntry(address(tokenB), spenderB);

        vm.expectRevert(abi.encodeWithSelector(IApprovalGuard.NonZeroAllowance.selector, address(tokenB), spenderB, 50));
        guard.checkZeroAllowances(entries);
    }

    function testDifferentCallerNotAffected() public {
        // Set allowance for a different owner — should not affect our check
        tokenA.setAllowance(makeAddr("other"), spenderA, 100);

        ApprovalEntry[] memory entries = new ApprovalEntry[](1);
        entries[0] = ApprovalEntry(address(tokenA), spenderA);

        // Passes because allowance(address(this), spenderA) is still 0
        guard.checkZeroAllowances(entries);
    }
}
