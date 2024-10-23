// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.28;

import "forge-std/Test.sol";
import "forge-std/mocks/MockERC20.sol";
import "src/NftEscrow.sol";
import "src/interfaces/INftEscrow.sol";

contract TestCommon is Test {
    address constant OWNER = address(42);
    uint256 constant TOKEN_ID = 23;
    uint256 constant DECIMALS = 6;
    uint256 constant ELEMENT_ID = 18;

    NftEscrow escrow = new NftEscrow(address(this));
    IERC6909 nfts = IERC6909(address(0));

    uint160 immutable NFT_ID = escrow.computeNftId(nfts, TOKEN_ID);

    function setUp() public {
        vm.mockCall(address(nfts), abi.encodeWithSelector(IERC6909.decimals.selector), abi.encode(DECIMALS));
    }

    function _mockEscrowBalance(uint256 balance) internal {
        vm.mockCall(
            address(nfts),
            abi.encodeWithSelector(IERC6909.balanceOf.selector, address(escrow), TOKEN_ID),
            abi.encode(balance)
        );
    }

    function _mockTransfer(address from, address to, bool result) internal {
        vm.mockCall(
            address(nfts),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, from, to, TOKEN_ID, 10 ** DECIMALS),
            abi.encode(result)
        );
    }
}

contract TestLock is TestCommon {
    function testSuccess() public {
        vm.expectEmit();
        emit INftEscrow.Locked(nfts, TOKEN_ID);
        _mockEscrowBalance(0);
        _mockTransfer(OWNER, address(escrow), true);

        escrow.lock(nfts, TOKEN_ID, OWNER);
    }

    function testErrAlreadyLocked() public {
        _mockEscrowBalance(1);
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.AlreadyLocked.selector));

        escrow.lock(nfts, TOKEN_ID, OWNER);
    }

    function testErrCanNotBeTransferred() public {
        _mockEscrowBalance(0);
        _mockTransfer(OWNER, address(escrow), false);
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.CanNotBeTransferred.selector));

        escrow.lock(nfts, TOKEN_ID, OWNER);
    }
}

contract TestUnlock is TestCommon {
    function testSuccess() public {
        vm.expectEmit();
        emit INftEscrow.Unlocked(nfts, TOKEN_ID);
        _mockTransfer(address(escrow), OWNER, true);

        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }

    function testErrAlreadyAttached() public {
        _mockEscrowBalance(1);
        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.AlreadyAttached.selector));

        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }

    function testErrCanNotBeTransferred() public {
        _mockTransfer(address(escrow), OWNER, false);
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.CanNotBeTransferred.selector));

        escrow.unlock(nfts, TOKEN_ID, OWNER);
    }
}

contract TestAttach is TestCommon {
    function testSuccess() public {
        vm.expectEmit();
        emit INftEscrow.Attached(NFT_ID, ELEMENT_ID);
        _mockEscrowBalance(1);

        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);
    }

    function testErrInvalidElement() public {
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.InvalidElement.selector));

        escrow.attach(nfts, TOKEN_ID, 0);
    }

    function testErrAlreadyAttached() public {
        _mockEscrowBalance(1);
        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);

        vm.expectRevert(abi.encodeWithSelector(INftEscrow.AlreadyAttached.selector));

        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);
    }

    function testErrNotLocked() public {
        _mockEscrowBalance(0);
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.NotLocked.selector));

        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);
    }
}

contract TestDetach is TestCommon {
    function testSuccess() public {
        _mockEscrowBalance(1);

        escrow.attach(nfts, TOKEN_ID, ELEMENT_ID);

        vm.expectEmit();
        emit INftEscrow.Detached(NFT_ID, ELEMENT_ID);

        escrow.detach(NFT_ID);
    }

    function testErrNotAttached() public {
        vm.expectRevert(abi.encodeWithSelector(INftEscrow.NotAttached.selector));
        escrow.detach(NFT_ID);
    }
}
