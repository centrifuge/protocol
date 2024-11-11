// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.28;

import "forge-std/Test.sol";
import "src/NftEscrow.sol";
import "src/interfaces/INftEscrow.sol";

contract TestCommon is Test {
    address constant OWNER = address(42);
    uint256 constant TOKEN_ID = 23;
    uint256 constant ELEMENT_ID = 18;

    NftEscrow escrow = new NftEscrow(address(this));
    IERC6909 nfts = IERC6909(address(0));

    uint160 immutable NFT_ID = escrow.computeNftId(nfts, TOKEN_ID);

    function _mockBalanceOf(uint256 balance) internal {
        vm.mockCall(
            address(nfts),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(escrow), TOKEN_ID),
            abi.encode(balance)
        );
    }

    function _mockTransferFrom(address from, address to, bool result) internal {
        vm.mockCall(
            address(nfts),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, from, to, TOKEN_ID, 1),
            abi.encode(result)
        );
    }
}

contract TestLock is TestCommon {
    function testSuccess() public {
        _mockBalanceOf(0);
        _mockTransferFrom(OWNER, address(escrow), true);

        vm.expectEmit();
        emit INftEscrow.Locked(nfts, TOKEN_ID);
        escrow.lock(nfts, TOKEN_ID, OWNER);
    }

    function testErrAlreadyLocked() public {
        _mockBalanceOf(1);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.AlreadyLocked.selector));
        escrow.lock(nfts, TOKEN_ID, OWNER);
    }

    function testErrCanNotBeTransferred() public {
        _mockBalanceOf(0);
        _mockTransferFrom(OWNER, address(escrow), false);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.CanNotBeTransferred.selector));
        escrow.lock(nfts, TOKEN_ID, OWNER);
    }
}

contract TestUnlock is TestCommon {
    function testSuccess() public {
        _mockBalanceOf(1);
        _mockTransferFrom(address(escrow), OWNER, true);

        vm.expectEmit();
        emit INftEscrow.Unlocked(nfts, TOKEN_ID);
        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }

    function testErrNotLocked() public {
        _mockBalanceOf(0);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.NotLocked.selector));
        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }

    function testErrCanNotBeTransferred() public {
        _mockBalanceOf(1);
        _mockTransferFrom(address(escrow), OWNER, false);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.CanNotBeTransferred.selector));
        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }
}
