// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {Escrow, PoolEscrow} from "src/vaults/Escrow.sol";
import {IEscrow, IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";

contract EscrowTestBase is Test {
    address spender = makeAddr("spender");
    address randomUser = makeAddr("randomUser");
    Escrow escrow = new Escrow(address(this));
    ERC20 erc20 = new ERC20(6);
    MockERC6909 erc6909 = new MockERC6909();

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

contract EscrowTestERC6909 is EscrowTestBase {}

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
        escrow.reserveIncrease(scId, asset, tokenId, 100);

        vm.expectEmit();
        emit IPoolEscrow.IncreaseReserve(asset, tokenId, poolId, scId, 100, 100);
        escrow.reserveIncrease(scId, asset, tokenId, 100);

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
        escrow.reserveIncrease(scId, asset, tokenId, 100);

        escrow.reserveIncrease(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Still zero, nothing is in holdings");

        _mint(address(escrow), tokenId, 300);
        escrow.deposit(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "100 - 100 = 0");

        escrow.deposit(scId, asset, tokenId, 200);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 200, "300 - 100 = 200");

        vm.expectRevert(IPoolEscrow.InsufficientReservedAmount.selector);
        escrow.reserveDecrease(scId, asset, tokenId, 200);

        vm.expectEmit();
        emit IPoolEscrow.DecreaseReserve(asset, tokenId, poolId, scId, 100, 0);
        escrow.reserveDecrease(scId, asset, tokenId, 100);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "300 - 0 = 300");
    }

    function _testWithdraw(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        _mint(address(escrow), tokenId, 1000);
        escrow.deposit(scId, asset, tokenId, 1000);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 1000, "initial holdings should be 1000");

        escrow.reserveIncrease(scId, asset, tokenId, 500);

        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, asset, tokenId, 600, 500));
        escrow.withdraw(scId, asset, tokenId, 600);

        vm.expectEmit();
        emit IPoolEscrow.Withdraw(asset, tokenId, poolId, scId, 500);
        escrow.withdraw(scId, asset, tokenId, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0);
    }

    function _testAvailableBalanceOf(PoolId poolId, ShareClassId scId, uint256 tokenId) internal {
        address asset = _asset(tokenId);
        PoolEscrow escrow = new PoolEscrow(poolId, address(this));

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Default available balance should be zero");

        _mint(address(escrow), tokenId, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Available balance needs deposit first.");

        escrow.deposit(scId, asset, tokenId, 500);

        escrow.reserveIncrease(scId, asset, tokenId, 200);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "Should be 300 after reserve increase");

        escrow.reserveIncrease(scId, asset, tokenId, 300);
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

    function testAvailableBalanceOf(PoolId poolId, ShareClassId scId, uint8 tokenId_) public {
        uint256 tokenId = uint256(bound(tokenId_, 2, 18));

        _testAvailableBalanceOf(poolId, scId, tokenId);
    }
}
