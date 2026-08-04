// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {Escrow, IEscrow} from "../../../src/misc/Escrow.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {TransferFailed} from "../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {PoolEscrow, IPoolEscrow} from "../../../src/core/spoke/PoolEscrow.sol";

import "forge-std/Test.sol";

contract EscrowTestBase is Test {
    address spender = makeAddr("spender");
    address randomUser = makeAddr("randomUser");
    Escrow escrow = new Escrow(address(this));
    ERC20 erc20 = new ERC20(6);
    MockERC6909 erc6909 = new MockERC6909();

    bytes32 constant RESERVE_REASON = bytes32(uint256(1));
    /// @dev A wide, derived reason (the shape the bytes32 widening exists for, e.g. per-request buckets)
    ///      alongside the narrow sentinel above.
    bytes32 constant RESERVE_REASON_DERIVED = keccak256(abi.encodePacked(bytes32(uint256(1)), uint256(42)));

    function _mint(address escrow_, uint256 tokenId, uint256 amount) internal {
        if (tokenId == 0) {
            erc20.mint(escrow_, amount);
        } else {
            erc6909.mint(escrow_, tokenId, amount);
        }
    }

    function _asset(uint256 tokenId) internal view returns (address) {
        return tokenId == 0 ? address(erc20) : address(erc6909);
    }
}

contract EscrowTestERC20 is EscrowTestBase {}

contract EscrowTestERC6909 is EscrowTestBase {
    function testAuthTransferToRevertsOnFalseReturn() public {
        uint256 tokenId = 2;
        _mint(address(escrow), tokenId, 100);

        // An ERC-6909 token returning false instead of reverting must not pass silently.
        vm.mockCall(
            address(erc6909),
            abi.encodeWithSelector(MockERC6909.transfer.selector, spender, tokenId, uint256(100)),
            abi.encode(false)
        );

        vm.expectRevert(TransferFailed.selector);
        escrow.authTransferTo(address(erc6909), tokenId, spender, 100);
    }
}

contract PoolEscrowTestBase is EscrowTestBase {
    function _testDeposit(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        vm.expectEmit();
        emit IPoolEscrow.Deposit(asset, tokenId, poolId, scId, 300);
        escrow.deposit(scId, asset, tokenId, 300);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "holdings should be 300 after deposit");

        vm.expectEmit();
        emit IPoolEscrow.Deposit(asset, tokenId, poolId, scId, 200);
        escrow.deposit(scId, asset, tokenId, 200);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 500, "holdings should be 500 after deposit");
    }

    function _testReserveIncrease(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserve(scId, asset, tokenId, 100, randomUser, RESERVE_REASON);

        vm.expectEmit();
        emit IPoolEscrow.IncreaseReserve(asset, tokenId, poolId, scId, address(this), RESERVE_REASON, 100, 100);
        escrow.reserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Still zero, nothing is in holdings");

        _mint(address(escrow), tokenId, 300);
        escrow.deposit(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "100 - 100 = 0");

        escrow.deposit(scId, asset, tokenId, 200);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 200, "300 - 100 = 200");
    }

    function _testReserveDecrease(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserve(scId, asset, tokenId, 100, randomUser, RESERVE_REASON);

        escrow.reserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Still zero, nothing is in holdings");

        _mint(address(escrow), tokenId, 300);
        escrow.deposit(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "100 - 100 = 0");

        escrow.deposit(scId, asset, tokenId, 200);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 200, "300 - 100 = 200");

        vm.expectRevert(IPoolEscrow.InsufficientReserve.selector);
        escrow.unreserve(scId, asset, tokenId, 200, address(this), RESERVE_REASON);

        vm.expectEmit();
        emit IPoolEscrow.DecreaseReserve(asset, tokenId, poolId, scId, address(this), RESERVE_REASON, 100, 0);
        escrow.unreserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "300 - 0 = 300");
    }

    /// @dev Two distinct reasons under the same reserver must keep independent balances: unreserving against
    ///      one bucket must not be payable out of the other, and `holding.reserved` must be their sum. This is
    ///      what the bytes32 reason widening is for, so it is asserted against a keccak-derived reason too.
    function _testReserveBucketIsolation(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        _mint(address(escrow), tokenId, 1000);
        escrow.deposit(scId, asset, tokenId, 1000);

        escrow.reserve(scId, asset, tokenId, 300, address(this), RESERVE_REASON);
        escrow.reserve(scId, asset, tokenId, 200, address(this), RESERVE_REASON_DERIVED);

        // Buckets are tracked separately...
        assertEq(escrow.reservedBy(scId, address(this), RESERVE_REASON, asset, tokenId), 300, "bucket A is 300");
        assertEq(escrow.reservedBy(scId, address(this), RESERVE_REASON_DERIVED, asset, tokenId), 200, "bucket B is 200");
        // ...and the holding reserves their sum, so available balance nets both.
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 500, "1000 - (300 + 200) = 500");

        // Bucket B cannot be drained against bucket A's reservation, even though the holding total covers it.
        vm.expectRevert(IPoolEscrow.InsufficientReserve.selector);
        escrow.unreserve(scId, asset, tokenId, 300, address(this), RESERVE_REASON_DERIVED);

        // The same amount against its own bucket succeeds and leaves the other bucket untouched.
        escrow.unreserve(scId, asset, tokenId, 300, address(this), RESERVE_REASON);
        assertEq(escrow.reservedBy(scId, address(this), RESERVE_REASON, asset, tokenId), 0, "bucket A drained");
        assertEq(escrow.reservedBy(scId, address(this), RESERVE_REASON_DERIVED, asset, tokenId), 200, "bucket B intact");
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 800, "1000 - 200 = 800");

        // A different reserver with the same reason is a third, independent bucket.
        escrow.reserve(scId, asset, tokenId, 100, randomUser, RESERVE_REASON);
        assertEq(escrow.reservedBy(scId, randomUser, RESERVE_REASON, asset, tokenId), 100, "other reserver is 100");
        assertEq(escrow.reservedBy(scId, address(this), RESERVE_REASON, asset, tokenId), 0, "own bucket still 0");
    }

    function _testWithdraw(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        _mint(address(escrow), tokenId, 1000);
        escrow.deposit(scId, asset, tokenId, 1000);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 1000, "initial holdings should be 1000");

        escrow.reserve(scId, asset, tokenId, 500, address(this), RESERVE_REASON);

        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, asset, tokenId, 600, 500));
        escrow.withdraw(scId, asset, tokenId, randomUser, 600);

        escrow.reserve(scId, asset, tokenId, 600, address(this), RESERVE_REASON);

        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, asset, tokenId, 600, 0));
        escrow.withdraw(scId, asset, tokenId, randomUser, 600);

        escrow.unreserve(scId, asset, tokenId, 600, address(this), RESERVE_REASON);

        vm.expectEmit();
        emit IPoolEscrow.Withdraw(asset, tokenId, poolId, scId, randomUser, 500);
        escrow.withdraw(scId, asset, tokenId, randomUser, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0);
    }

    function _testAvailableBalanceOf(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Default available balance should be zero");

        _mint(address(escrow), tokenId, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Available balance needs deposit first.");

        escrow.deposit(scId, asset, tokenId, 500);

        escrow.reserve(scId, asset, tokenId, 200, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "Should be 300 after reserve increase");

        escrow.reserve(scId, asset, tokenId, 300, address(this), RESERVE_REASON);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Should be zero if pendingWithdraw >= holdings");
    }
}

contract PoolEscrowTestERC20 is PoolEscrowTestBase {
    uint256 tokenId = 0;

    function testDeposit(PoolId poolId, ShareClassId scId) public {
        _testDeposit(poolId, scId, tokenId);
    }

    function testReserveIncrease(PoolId poolId, ShareClassId scId) public {
        _testReserveIncrease(poolId, scId, tokenId);
    }

    function testReserveDecrease(PoolId poolId, ShareClassId scId) public {
        _testReserveDecrease(poolId, scId, tokenId);
    }

    function testWithdraw(PoolId poolId, ShareClassId scId) public {
        _testWithdraw(poolId, scId, tokenId);
    }

    function testReserveBucketIsolation(PoolId poolId, ShareClassId scId) public {
        _testReserveBucketIsolation(poolId, scId, tokenId);
    }

    function testAvailableBalanceOf(PoolId poolId, ShareClassId scId) public {
        _testAvailableBalanceOf(poolId, scId, tokenId);
    }
}

contract PoolEscrowTestERC6909 is PoolEscrowTestBase {
    function testDeposit(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testDeposit(poolId, scId, tokenId);

        assertEq(erc6909.balanceOf(address(escrow), tokenId), 0, "Escrow should not hold any tokens after noting");
    }

    function testReserveIncrease(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testReserveIncrease(poolId, scId, tokenId);
    }

    function testReserveDecrease(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testReserveDecrease(poolId, scId, tokenId);
    }

    function testWithdraw(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testWithdraw(poolId, scId, tokenId);
    }

    function testReserveBucketIsolation(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testReserveBucketIsolation(poolId, scId, tokenId);
    }

    function testAvailableBalanceOf(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testAvailableBalanceOf(poolId, scId, tokenId);
    }
}
