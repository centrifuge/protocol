// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {TransferFailed} from "../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Escrow, IEscrow} from "../../../src/core/spoke/Escrow.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import "forge-std/Test.sol";

abstract contract EscrowTestBase is Test {
    address spender = makeAddr("spender");
    address randomUser = makeAddr("randomUser");
    ERC20 erc20 = new ERC20(6);
    MockERC6909 erc6909 = new MockERC6909();

    bytes32 constant RESERVE_REASON = bytes32(uint256(1));
    /// @dev A wide, derived reason (the shape the bytes32 widening exists for, e.g. per-request buckets)
    ///      alongside the narrow sentinel above.
    bytes32 constant RESERVE_REASON_DERIVED = keccak256(abi.encodePacked(bytes32(uint256(1)), uint256(42)));

    /// @dev ERC20 is token id zero; ERC6909 turns the fuzzed seed into an id. Every test takes the seed, so both
    ///      subclasses run the same bodies against their own token standard.
    function _tokenId(uint8 seed) internal virtual returns (uint256);

    function _mint(address escrow_, uint256 tokenId, uint256 amount) internal {
        if (tokenId == 0) {
            erc20.mint(escrow_, amount);
        } else {
            erc6909.mint(escrow_, tokenId, amount);
        }
    }

    function _balanceOf(address holder, uint256 tokenId) internal view returns (uint256) {
        return tokenId == 0 ? erc20.balanceOf(holder) : erc6909.balanceOf(holder, tokenId);
    }

    function _asset(uint256 tokenId) internal view returns (address) {
        return tokenId == 0 ? address(erc20) : address(erc6909);
    }
}

abstract contract EscrowAuthTransferTestBase is EscrowTestBase {
    Escrow escrow = new Escrow(PoolId.wrap(1), address(this));

    function testAuthTransferTo(uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        _mint(address(escrow), tokenId, 100);

        vm.expectEmit();
        emit IEscrow.AuthTransferTo(asset, tokenId, spender, 100);
        escrow.authTransferTo(asset, tokenId, spender, 100);

        assertEq(_balanceOf(spender, tokenId), 100, "receiver holds the transferred tokens");
        assertEq(_balanceOf(address(escrow), tokenId), 0, "escrow holds nothing afterwards");
    }

    function testAuthTransferToRevertsOnInsufficientBalance(uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        _mint(address(escrow), tokenId, 100);

        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, asset, tokenId, 101, 100));
        escrow.authTransferTo(asset, tokenId, spender, 101);
    }

    function testAuthTransferToRevertsOnUnauthorized(uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        _mint(address(escrow), tokenId, 100);

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.authTransferTo(_asset(tokenId), tokenId, spender, 100);
    }
}

contract EscrowAuthTransferTestERC20 is EscrowAuthTransferTestBase {
    function _tokenId(uint8) internal pure override returns (uint256) {
        return 0;
    }
}

contract EscrowAuthTransferTestERC6909 is EscrowAuthTransferTestBase {
    function _tokenId(uint8 seed) internal pure override returns (uint256) {
        return _bound(uint256(seed), 2, 18);
    }

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

abstract contract EscrowHoldingTestBase is EscrowTestBase {
    function testDeposit(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

        vm.expectEmit();
        emit IEscrow.Deposit(asset, tokenId, poolId, scId, 300);
        escrow.deposit(scId, asset, tokenId, 300);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "holdings should be 300 after deposit");

        vm.expectEmit();
        emit IEscrow.Deposit(asset, tokenId, poolId, scId, 200);
        escrow.deposit(scId, asset, tokenId, 200);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 500, "holdings should be 500 after deposit");
        assertEq(_balanceOf(address(escrow), tokenId), 0, "deposit only notes the holding, it moves no tokens");
    }

    function testReserveIncrease(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.reserve(scId, asset, tokenId, 100, randomUser, RESERVE_REASON);

        vm.expectEmit();
        emit IEscrow.IncreaseReserve(asset, tokenId, poolId, scId, address(this), RESERVE_REASON, 100, 100);
        escrow.reserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Still zero, nothing is in holdings");

        _mint(address(escrow), tokenId, 300);
        escrow.deposit(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "100 - 100 = 0");

        escrow.deposit(scId, asset, tokenId, 200);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 200, "300 - 100 = 200");
    }

    function testReserveDecrease(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.unreserve(scId, asset, tokenId, 100, randomUser, RESERVE_REASON);

        escrow.reserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Still zero, nothing is in holdings");

        _mint(address(escrow), tokenId, 300);
        escrow.deposit(scId, asset, tokenId, 100);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "100 - 100 = 0");

        escrow.deposit(scId, asset, tokenId, 200);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 200, "300 - 100 = 200");

        vm.expectRevert(IEscrow.InsufficientReserve.selector);
        escrow.unreserve(scId, asset, tokenId, 200, address(this), RESERVE_REASON);

        vm.expectEmit();
        emit IEscrow.DecreaseReserve(asset, tokenId, poolId, scId, address(this), RESERVE_REASON, 100, 0);
        escrow.unreserve(scId, asset, tokenId, 100, address(this), RESERVE_REASON);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "300 - 0 = 300");
    }

    /// @dev Two distinct reasons under the same reserver must keep independent balances: unreserving against
    ///      one bucket must not be payable out of the other, and `holding.reserved` must be their sum. This is
    ///      what the bytes32 reason widening is for, so it is asserted against a keccak-derived reason too.
    function testReserveBucketIsolation(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

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
        vm.expectRevert(IEscrow.InsufficientReserve.selector);
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

    function testWithdraw(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

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
        emit IEscrow.Withdraw(asset, tokenId, poolId, scId, randomUser, 500);
        escrow.withdraw(scId, asset, tokenId, randomUser, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0);
    }

    function testWithdrawRevertsOnUnauthorized(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        Escrow escrow = new Escrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.withdraw(scId, _asset(tokenId), tokenId, randomUser, 1);
    }

    function testDepositRevertsOnUnauthorized(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        Escrow escrow = new Escrow(poolId, address(this));

        vm.prank(randomUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        escrow.deposit(scId, _asset(tokenId), tokenId, 1);
    }

    function testAvailableBalanceOf(PoolId poolId, ShareClassId scId, uint8 seed) public {
        uint256 tokenId = _tokenId(seed);
        address asset = _asset(tokenId);
        Escrow escrow = new Escrow(poolId, address(this));

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Default available balance should be zero");

        _mint(address(escrow), tokenId, 500);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Available balance needs deposit first.");

        escrow.deposit(scId, asset, tokenId, 500);

        escrow.reserve(scId, asset, tokenId, 200, address(this), RESERVE_REASON);

        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 300, "Should be 300 after reserve increase");

        escrow.reserve(scId, asset, tokenId, 300, address(this), RESERVE_REASON);
        assertEq(escrow.availableBalanceOf(scId, asset, tokenId), 0, "Should be zero if pendingWithdraw >= holdings");
    }

    function testPoolId(PoolId poolId) public {
        assertEq(new Escrow(poolId, address(this)).poolId().raw(), poolId.raw(), "poolId is the one constructed with");
    }
}

contract EscrowHoldingTestERC20 is EscrowHoldingTestBase {
    function _tokenId(uint8) internal pure override returns (uint256) {
        return 0;
    }
}

contract EscrowHoldingTestERC6909 is EscrowHoldingTestBase {
    function _tokenId(uint8 seed) internal pure override returns (uint256) {
        return _bound(uint256(seed), 2, 18);
    }
}
