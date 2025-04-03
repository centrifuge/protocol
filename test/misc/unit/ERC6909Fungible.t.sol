// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {ERC6909Fungible} from "src/misc/ERC6909Fungible.sol";

abstract contract ERC6909FungibleBaseTest is Test {
    address self;
    ERC6909Fungible token;
    uint256 tokenId = 1;

    function setUp() public virtual {
        self = address(this);
        token = new ERC6909Fungible(self);
    }
}

contract ERC6909FungibleAuthTest is ERC6909FungibleBaseTest {
    address unauhtorized = address(0xdeadbeef);

    function testWardsSetupOnInitialization() public view {
        assertEq(token.wards(self), 1);
    }

    function testAddingAWard() public {
        address newWard = makeAddr("ward");

        assertEq(token.wards(newWard), 0);
        token.rely(newWard);
        assertEq(token.wards(newWard), 1);
    }

    function testRemovingAWard() public {
        assertEq(token.wards(self), 1);
        token.deny(self);
        assertEq(token.wards(self), 0);
    }

    function testRevertOnUnauthorizedMint() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauhtorized);
        token.mint(self, 1, 1000);
    }

    function testRevertOnUnauthorizedBurn() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(unauhtorized);
        token.burn(self, 1, 1000);
    }

    function testRevertOnUnauthorizedTransfer() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(makeAddr("unauthorized"));
        token.authTransferFrom(makeAddr("from"), makeAddr("to"), 1, 1000);
    }
}

contract ERC6909FungibleTokenMintTest is ERC6909FungibleBaseTest {
    function testSuccessfulMinting(uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        token.mint(self, tokenId, amount);
        assertEq(token.balanceOf(self, tokenId), amount);
    }

    function testMultipleSuccessfullMints() public {
        uint256 firstMint = 1000;
        uint256 secondMint = 2000;
        uint256 total = firstMint + secondMint;
        address anotherOwner = makeAddr("anotherOwner");

        token.mint(self, tokenId, firstMint);
        assertEq(token.balanceOf(self, tokenId), firstMint);
        token.mint(anotherOwner, tokenId, secondMint);
        assertEq(token.balanceOf(anotherOwner, tokenId), secondMint);
    }

    function testRevertOnBigSupply() public {
        token.mint(self, tokenId, type(uint256).max);

        vm.expectRevert(stdError.arithmeticError); // Generic built-in overflow error
        token.mint(self, tokenId, type(uint256).max);
    }
}

contract ERC6909FungibleTokenBurntest is ERC6909FungibleBaseTest {
    uint256 totalSupply;

    function setUp() public override {
        super.setUp();
        totalSupply = type(uint256).max;
        token.mint(self, tokenId, totalSupply);
    }

    function testSuccessfulBurn(uint256 amount) public {
        token.burn(self, tokenId, amount);
        assertEq(token.balanceOf(self, tokenId), totalSupply - amount);
    }

    function testMultipleSuccessfulBurns() public {
        uint256 amount = 1000;
        uint256 anotherTokenId = tokenId + 1;
        address anotherOwner = makeAddr("anotherOwner");

        token.burn(self, tokenId, amount);
        token.burn(self, tokenId, amount);

        uint256 currentSupply = totalSupply - 2 * amount;

        assertEq(token.balanceOf(self, tokenId), currentSupply);

        // Testing for another owner of the same token
        assertEq(token.balanceOf(anotherOwner, tokenId), 0);
        token.mint(anotherOwner, tokenId, amount);
        assertEq(token.balanceOf(anotherOwner, tokenId), amount);

        token.burn(anotherOwner, tokenId, amount);
        assertEq(token.balanceOf(anotherOwner, tokenId), 0);

        // Testing for another token for the same user
        assertEq(token.balanceOf(self, anotherTokenId), 0);

        token.mint(self, anotherTokenId, amount);

        assertEq(token.balanceOf(self, anotherTokenId), amount);

        token.burn(self, anotherTokenId, amount);

        assertEq(token.balanceOf(self, anotherTokenId), 0);
    }

    function testRevertOnInsufficientBalance() public {
        uint256 balance = token.balanceOf(self, tokenId);
        token.burn(self, tokenId, balance);
        assertEq(token.balanceOf(self, tokenId), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, self, tokenId));
        token.burn(self, tokenId, balance);
    }
}

contract ERC6909FungibleAuthorizedTransferTest is ERC6909FungibleBaseTest {
    function testSuccessfulAuthorizedTransfer() public {
        address owner = makeAddr("owner");
        uint256 amount = 1000;

        token.mint(owner, tokenId, amount);
        assertEq(token.balanceOf(owner, tokenId), 1000);

        token.authTransferFrom(owner, self, tokenId, amount);
        assertEq(token.balanceOf(owner, tokenId), 0);
        assertEq(token.balanceOf(self, tokenId), amount);
    }
}
