// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC6909NFT} from "src/ERC6909/ERC6909NFT.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC6909NFT} from "src/interfaces/ERC6909/IERC6909NFT.sol";
import {IERC6909URIExt} from "src/interfaces/ERC6909/IERC6909URIExt.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IAuth} from "src/interfaces/IAuth.sol";

contract ERC6909NFTTest is Test {
    using StringLib for string;

    string constant EMPTY = "";
    uint256 constant MAX_SUPPLY = 1;
    address immutable self;

    ERC6909NFT token;

    constructor() {
        self = address(this);
    }

    function setUp() public {
        token = new ERC6909NFT(self);
    }

    function testAuthorizations(address owner) public {
        vm.assume(owner != address(0) && owner != self);
        token = new ERC6909NFT(owner);
        assertEq(token.wards(owner), 1);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.rely(self);

        vm.prank(owner);
        token.rely(self);

        assertEq(token.wards(owner), 1);
        assertEq(token.wards(self), 1);

        token.deny(owner);
        assertEq(token.wards(owner), 0);
        assertEq(token.wards(self), 1);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(owner);
        token.deny(self);
    }

    function testMintingNewItem(address owner, string calldata URI) public {
        vm.assume(owner != address(0));
        vm.assume(!URI.isEmpty());

        vm.expectRevert(IERC6909.EmptyOwner.selector);
        token.mint(address(0), URI);

        vm.expectRevert(IERC6909URIExt.EmptyURI.selector);
        token.mint(owner, "");

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(makeAddr("unauthorized"));
        token.mint(owner, URI);

        assertEq(token.latestTokenId(), 0);
        uint256 tokenId = token.mint(owner, URI);

        assertEq(token.latestTokenId(), 1);
        assertEq(token.latestTokenId(), tokenId);
        assertEq(token.balanceOf(owner, tokenId), MAX_SUPPLY);
        assertEq(token.tokenURI(tokenId), URI);
    }

    function testBurningToken() public {
        string memory URI = "some/random/URI";
        address owner = self;

        uint256 tokenId = token.mint(owner, URI);

        assertEq(token.balanceOf(owner, tokenId), MAX_SUPPLY);
        token.burn(tokenId);
        assertEq(token.balanceOf(owner, tokenId), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, owner, tokenId));
        token.burn(tokenId);
    }

    function testSettingContractURI(string calldata URI) public {
        token.setContractURI(URI);
        assertEq(token.contractURI(), URI);

        vm.expectRevert(IAuth.NotAuthorized.selector);
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

    function testTransfer() public {
        address receiver = makeAddr("receiver");
        string memory URI = "some/random";

        uint256 tokenId = token.mint(self, URI);

        bool isSuccessful = token.transfer(receiver, tokenId, MAX_SUPPLY);
        assertTrue(isSuccessful);

        assertEq(token.balanceOf(self, tokenId), 0);
        assertEq(token.balanceOf(receiver, tokenId), MAX_SUPPLY);

        // Testing non-existing owner with an existing tokenId where the balance will be 0
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, self, tokenId));
        token.transfer(makeAddr("random"), tokenId, MAX_SUPPLY);

        // Testing non-existing tokenId where the balance will be 0
        uint256 nonExistingTokenId = 1337;
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientBalance.selector, self, nonExistingTokenId));
        token.transfer(receiver, nonExistingTokenId, MAX_SUPPLY);
    }

    function testTransferFrom() public {
        address operator = makeAddr("operator");
        address delegate = makeAddr("delegate");
        address receiver = makeAddr("receiver");

        string memory URI = "some/random/URI";
        uint256 tokenId = token.mint(self, URI); // tokenId = 1

        // Caller is neither operator, nor has allowance
        vm.expectRevert(abi.encodeWithSelector(IERC6909.InsufficientAllowance.selector, delegate, tokenId));
        vm.prank(delegate);
        bool isSuccessful = token.transferFrom(self, receiver, tokenId, MAX_SUPPLY);
        assertFalse(isSuccessful);

        assertEq(token.balanceOf(receiver, tokenId), 0);
        assertEq(token.balanceOf(self, tokenId), MAX_SUPPLY);

        // Caller is an operator and does not have allowance
        token.setOperator(operator, true);
        assertEq(token.allowance(self, operator, tokenId), 0);

        vm.prank(operator);
        isSuccessful = token.transferFrom(self, receiver, tokenId, MAX_SUPPLY);
        assertTrue(isSuccessful);

        assertEq(token.balanceOf(receiver, tokenId), MAX_SUPPLY);
        assertEq(token.balanceOf(self, tokenId), 0);

        // Caller has allowance and it is not an operator
        tokenId = token.mint(self, URI); // tokenId = 2
        uint256 allowance = MAX_SUPPLY;
        token.approve(delegate, tokenId, allowance);

        assertFalse(token.isOperator(self, delegate));
        assertEq(token.allowance(self, delegate, tokenId), allowance);

        vm.prank(delegate);
        isSuccessful = token.transferFrom(self, receiver, tokenId, MAX_SUPPLY);
        assertTrue(isSuccessful);

        assertEq(token.balanceOf(receiver, tokenId), MAX_SUPPLY);
        assertEq(token.balanceOf(self, tokenId), 0);
        assertEq(token.allowance(self, delegate, tokenId), 0);

        // Caller is actually the owner
        tokenId = token.mint(self, URI); // tokenId = 3

        isSuccessful = token.transferFrom(self, receiver, tokenId, MAX_SUPPLY);
        assertTrue(isSuccessful);

        assertEq(token.balanceOf(receiver, tokenId), MAX_SUPPLY);
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
