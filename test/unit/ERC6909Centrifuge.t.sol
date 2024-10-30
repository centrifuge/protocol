// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC6909Centrifuge} from "src/ERC6909/ERC6909Centrifuge.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC6909Centrifuge} from "src/interfaces/ERC6909/IERC6909Centrifuge.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC165} from "src/interfaces/IERC165.sol";

contract ERC6909CentrifugeTest is Test {
    using StringLib for string;

    string constant EMPTY = "";
    address immutable self;

    ERC6909Centrifuge token;

    constructor() {
        self = address(this);
    }

    function setUp() public {
        token = new ERC6909Centrifuge(self);
    }

    function testAuthorizations(address owner) public {
        vm.assume(owner != address(0));
        token = new ERC6909Centrifuge(owner);
        assertEq(token.wards(owner), 1);

        vm.expectRevert("Auth/not-authorized");
        token.rely(self);

        vm.prank(owner);
        token.rely(self);

        assertEq(token.wards(owner), 1);
        assertEq(token.wards(self), 1);

        token.deny(owner);
        assertEq(token.wards(owner), 0);
        assertEq(token.wards(self), 1);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(owner);
        token.deny(self);
    }

    function testMintingNewItem(address owner, uint256 amount, string calldata URI) public {
        vm.assume(owner != address(0));
        vm.assume(!URI.isEmpty());
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert(IERC6909Centrifuge.EmptyOwner.selector);
        token.mint(address(0), URI, amount);

        vm.expectRevert(IERC6909Centrifuge.EmptyURI.selector);
        token.mint(owner, "", amount);

        vm.expectRevert(IERC6909Centrifuge.EmptyAmount.selector);
        token.mint(owner, URI, 0);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        token.mint(owner, URI, amount);

        assertEq(token.latestTokenId(), 0);
        uint256 tokenId = token.mint(owner, URI, amount);

        assertEq(token.latestTokenId(), 1);
        assertEq(token.latestTokenId(), tokenId);
        assertEq(token.balanceOf(owner, tokenId), amount);
        assertEq(token.tokenURI(tokenId), URI);
        assertEq(token.totalSupply(tokenId), amount);
    }

    function testMintingOnExistingToken(address owner, uint256 amount) public {
        vm.assume(owner != address(0));
        uint256 MAX_UINT256 = type(uint256).max;
        uint256 offset = 10;
        amount = bound(amount, 1, MAX_UINT256 - offset);
        string memory URI = "some/random/URI";

        uint256 tokenId = token.mint(owner, URI, amount);
        uint256 balance = token.balanceOf(owner, tokenId);

        uint256 totalSupply = token.totalSupply(tokenId);
        assertEq(totalSupply, amount);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        token.mint(owner, tokenId, amount);

        vm.expectRevert(IERC6909Centrifuge.MaxSupplyReached.selector);
        token.mint(owner, tokenId, MAX_UINT256);

        uint256 latestBalance = token.mint(owner, tokenId, 0);
        assertEq(latestBalance, balance);

        uint256 nonExistingID = token.latestTokenId() + 1;
        vm.expectRevert(abi.encodeWithSelector(IERC6909Centrifuge.UnknownTokenId.selector, owner, nonExistingID));
        token.mint(owner, nonExistingID, amount);

        uint256 newBalance = token.mint(owner, tokenId, offset);
        assertEq(newBalance, balance + offset);
        assertEq(token.totalSupply(tokenId), totalSupply + offset);
    }

    function testBurningToken(uint256 amount) public {
        string memory URI = "some/random/URI";
        address owner = self;
        amount = bound(amount, 2, type(uint256).max - 1);

        uint256 tokenId = token.mint(owner, URI, amount);

        uint256 burnMoreThanHave = amount + 1;
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, owner, tokenId));
        token.burn(tokenId, burnMoreThanHave);

        assertEq(token.balanceOf(owner, tokenId), amount);

        uint256 burnAmount = amount - 1;
        uint256 remaining = token.burn(tokenId, burnAmount);
        assertEq(token.balanceOf(owner, tokenId), remaining);
        assertEq(remaining, 1);
        assertEq(token.totalSupply(tokenId), remaining);

        remaining = token.burn(tokenId, 0);
        assertEq(token.balanceOf(owner, tokenId), remaining);
        assertEq(remaining, 1);
        assertEq(token.totalSupply(tokenId), remaining);

        burnAmount = 1;
        remaining = token.burn(tokenId, burnAmount);
        assertEq(token.balanceOf(owner, tokenId), 0);
        assertEq(remaining, 0);
        assertEq(token.totalSupply(tokenId), 0);
    }

    function testSettingContractURI(string calldata URI) public {
        token.setContractURI(URI);
        assertEq(token.contractURI(), URI);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        token.setContractURI(URI);
    }

    function testSettingOperatorApproval(address operator) public {
        bool isSuccessful = token.setOperator(operator, true);
        assertTrue(isSuccessful);
        assertTrue(token.isOperator(self, operator));

        isSuccessful = token.setOperator(operator, false);
        assertTrue(isSuccessful);
        assertFalse(token.isOperator(self, operator));
    }

    function testTransfer(uint256 amount) public {
        address receiver = makeAddr("receiver");
        amount = bound(amount, 2, type(uint256).max);
        string memory URI = "some/random";

        uint256 tokenId = token.mint(self, URI, amount);

        uint256 half = amount / 2;
        bool isSuccessful = token.transfer(receiver, tokenId, half);

        assertTrue(isSuccessful);
        assertEq(token.balanceOf(self, tokenId), amount - half);
        assertEq(token.balanceOf(receiver, tokenId), half);

        // Testing non-existing owner with an existing tokenId where the balance will be 0
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, self, tokenId));
        token.transfer(makeAddr("random"), tokenId, amount);

        // Testing non-existing tokenId where the balance will be 0
        uint256 nonExistingTokenId = 1337;
        vm.expectRevert(
            abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, self, nonExistingTokenId)
        );
        token.transfer(receiver, nonExistingTokenId, amount);
    }

    function testTransferFrom() public {
        address operator = makeAddr("operator");
        address delegate = makeAddr("delegate");
        address receiver = makeAddr("receiver");

        uint256 amount = 32;
        string memory URI = "some/random/URI";
        uint256 tokenId = token.mint(self, URI, amount);

        uint256 sentAmount = amount / 2; // 16

        // Caller is neither operator, nor has allowance
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientAllowance.selector, delegate, tokenId));
        vm.prank(delegate);
        bool isSuccessful = token.transferFrom(self, receiver, tokenId, sentAmount);
        assertFalse(isSuccessful);

        assertEq(token.balanceOf(receiver, tokenId), 0);
        assertEq(token.balanceOf(self, tokenId), amount);

        // Caller is an operator and does not have allowance
        token.setOperator(operator, true);
        assertEq(token.allowance(self, operator, tokenId), 0);

        vm.prank(operator);
        isSuccessful = token.transferFrom(self, receiver, tokenId, sentAmount);
        assertTrue(isSuccessful);

        uint256 remainingBalance = amount - sentAmount; // 16
        assertEq(token.balanceOf(receiver, tokenId), sentAmount);
        assertEq(token.balanceOf(self, tokenId), remainingBalance);

        // Caller has allowance and it is not an operator
        uint256 receiverBalance = token.balanceOf(receiver, tokenId);
        uint256 allowance = remainingBalance;
        sentAmount = remainingBalance / 2; // 8
        token.approve(delegate, tokenId, allowance);

        assertFalse(token.isOperator(self, delegate));
        assertEq(token.allowance(self, delegate, tokenId), allowance);

        vm.prank(delegate);
        isSuccessful = token.transferFrom(self, receiver, tokenId, sentAmount);

        remainingBalance = remainingBalance - sentAmount; // 8

        assertTrue(isSuccessful);
        assertEq(token.balanceOf(receiver, tokenId), receiverBalance + sentAmount);
        assertEq(token.balanceOf(self, tokenId), remainingBalance);
        assertEq(token.allowance(self, delegate, tokenId), allowance - sentAmount);

        // Caller is actually the owner
        receiverBalance = token.balanceOf(receiver, tokenId);

        isSuccessful = token.transferFrom(self, receiver, tokenId, remainingBalance);

        assertTrue(isSuccessful);
        assertEq(token.balanceOf(receiver, tokenId), receiverBalance + remainingBalance);
        assertEq(token.balanceOf(self, tokenId), 0);
    }

    function testApprovals(address delegate, uint256 tokenId, uint256 amount) public {
        assertEq(token.allowance(self, delegate, tokenId), 0);

        bool isSuccessful = token.approve(delegate, tokenId, amount);
        assertTrue(isSuccessful);
        assertEq(token.allowance(self, delegate, tokenId), amount);

        isSuccessful = token.approve(delegate, tokenId, amount);
        assertTrue(isSuccessful);
        assertEq(token.allowance(self, delegate, tokenId), amount);

        uint256 newAllowance = 1337;
        isSuccessful = token.approve(delegate, tokenId, newAllowance);
        assertTrue(isSuccessful);
        assertEq(token.allowance(self, delegate, tokenId), newAllowance);
    }

    function testInterfaceSupport() public view {
        assertTrue(token.supportsInterface(type(IERC6909).interfaceId));
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
    }
}
