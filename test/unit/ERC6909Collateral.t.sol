// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "src/ERC6909/ERC6909Errors.sol";
import {ERC6909Collateral} from "src/ERC6909/ERC6909Collateral.sol";
import {IERC6909URIExtension} from "src/interfaces/ERC6909/IERC6909URIExtension.sol";
import {StringLib} from "src/libraries/StringLib.sol";
import {OverflowUint256} from "src/Errors.sol";

contract ERC6909CollateralTest is Test {
    using StringLib for string;

    string constant EMPTY = "";
    address immutable self;

    ERC6909Collateral collateral;

    constructor() {
        self = address(this);
    }

    function setUp() public {
        collateral = new ERC6909Collateral(self);
    }

    function testAuthorizations(address owner) public {
        vm.assume(owner != address(0));
        collateral = new ERC6909Collateral(owner);
        assertEq(collateral.wards(owner), 1);

        vm.expectRevert("Auth/not-authorized");
        collateral.rely(self);

        vm.prank(owner);
        collateral.rely(self);

        assertEq(collateral.wards(owner), 1);
        assertEq(collateral.wards(self), 1);

        collateral.deny(owner);
        assertEq(collateral.wards(owner), 0);
        assertEq(collateral.wards(self), 1);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(owner);
        collateral.deny(self);
    }

    function testMintingNewItem(address owner, uint256 amount, string calldata URI) public {
        vm.assume(owner != address(0));
        vm.assume(!URI.isEmpty());
        amount = bound(amount, 1, type(uint256).max);

        vm.expectRevert(ERC6909Collateral_Mint_EmptyOwner.selector);
        collateral.mint(address(0), URI, amount);

        vm.expectRevert(ERC6909Collateral_Mint_EmptyURI.selector);
        collateral.mint(owner, "", amount);

        vm.expectRevert(ERC6909Collateral_Mint_EmptyAmount.selector);
        collateral.mint(owner, URI, 0);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.mint(owner, URI, amount);

        assertEq(collateral.latestTokenId(), 0);
        uint256 tokenId = collateral.mint(owner, URI, amount);

        assertEq(collateral.latestTokenId(), 1);
        assertEq(collateral.latestTokenId(), tokenId);
        assertEq(collateral.balanceOf(owner, tokenId), amount);
        assertEq(collateral.tokenURI(tokenId), URI);
        assertEq(collateral.totalSupply(tokenId), amount);
    }

    function testMintingOnExistingToken(address owner, uint256 amount) public {
        vm.assume(owner != address(0));
        uint256 MAX_UINT256 = type(uint256).max;
        amount = bound(amount, 1, MAX_UINT256);
        string memory URI = "some/random/URI";

        uint256 tokenId = collateral.mint(owner, URI, amount);
        uint256 balance = collateral.balanceOf(owner, tokenId);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.mint(owner, tokenId, amount);

        vm.expectRevert(abi.encodeWithSelector(OverflowUint256.selector, balance, MAX_UINT256));
        collateral.mint(owner, tokenId, MAX_UINT256);

        uint256 latestBalance = collateral.mint(owner, tokenId, 0);
        assertEq(latestBalance, balance);

        uint256 nonExistingID = collateral.latestTokenId() + 1;
        vm.expectRevert(abi.encodeWithSelector(ERC6909Collateral_Mint_UnknownTokenId.selector, owner, nonExistingID));
        collateral.mint(owner, nonExistingID, amount);
    }

    function testBurningToken(address owner, uint256 amount) public {
        string memory URI = "some/random/URI";

        vm.assume(owner != address(0));
        amount = bound(amount, 2, type(uint256).max - 1);

        uint256 tokenId = collateral.mint(owner, URI, amount);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.burn(owner, tokenId, amount);

        uint256 burnMoreThanHave = amount + 1;
        vm.expectRevert(abi.encodeWithSelector(ERC6909Collateral_Burn_InsufficientBalance.selector, owner, tokenId));
        collateral.burn(owner, tokenId, burnMoreThanHave);

        assertEq(collateral.balanceOf(owner, tokenId), amount);

        uint256 burnAmount = amount - 1;
        uint256 remaining = collateral.burn(owner, tokenId, burnAmount);
        assertEq(collateral.balanceOf(owner, tokenId), remaining);
        assertEq(remaining, 1);
        assertEq(collateral.totalSupply(tokenId), remaining);

        remaining = collateral.burn(owner, tokenId, 0);
        assertEq(collateral.balanceOf(owner, tokenId), remaining);
        assertEq(remaining, 1);
        assertEq(collateral.totalSupply(tokenId), remaining);

        burnAmount = 1;
        remaining = collateral.burn(owner, tokenId, burnAmount);
        assertEq(collateral.balanceOf(owner, tokenId), 0);
        assertEq(remaining, 0);
        assertEq(collateral.totalSupply(tokenId), 0);
    }

    function testSettingSymbol(uint256 tokenId, string calldata symbol) public {
        collateral.setSymbol(tokenId, symbol);
        assertEq(collateral.symbol(tokenId), symbol);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.setSymbol(tokenId, symbol);
    }

    function testSettingName(uint256 tokenId, string calldata name) public {
        collateral.setName(tokenId, name);
        assertEq(collateral.name(tokenId), name);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.setName(tokenId, name);
    }

    function testSettingContractURI(string calldata URI) public {
        collateral.setContractURI(URI);
        assertEq(collateral.contractURI(), URI);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.setContractURI(URI);
    }

    function testSettingDecimals(uint256 tokenId) public {
        uint8 decimals = collateral.MIN_DECIMALS();

        collateral.setDecimals(tokenId, decimals);
        assertEq(collateral.decimals(tokenId), decimals);

        decimals = collateral.MIN_DECIMALS() - 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC6909Collateral_SetDecimal_LessThanMinimalDecimal.selector, collateral.MIN_DECIMALS(), decimals
            )
        );
        collateral.setDecimals(tokenId, decimals);

        vm.expectRevert("Auth/not-authorized");
        vm.prank(makeAddr("unauthorized"));
        collateral.setDecimals(tokenId, decimals);
    }

    function testSettingOperatorApproval(address operator) public {
        bool isSuccessful = collateral.setOperator(operator, true);
        assertTrue(isSuccessful);
        assertTrue(collateral.isOperator(self, operator));

        isSuccessful = collateral.setOperator(operator, false);
        assertTrue(isSuccessful);
        assertFalse(collateral.isOperator(self, operator));
    }

    function testTransfer(uint256 amount) public {
        address receiver = makeAddr("receiver");
        amount = bound(amount, 2, type(uint256).max);
        string memory URI = "some/random";

        uint256 tokenId = collateral.mint(self, URI, amount);

        uint256 half = amount / 2;
        bool isSuccessful = collateral.transfer(receiver, tokenId, half);

        assertTrue(isSuccessful);
        assertEq(collateral.balanceOf(self, tokenId), amount - half);
        assertEq(collateral.balanceOf(receiver, tokenId), half);

        // Testing non-existing owner with an existing tokenId where the balance will be 0
        vm.expectRevert(abi.encodeWithSelector(ERC6909_Transfer_InsufficientBalance.selector, self, tokenId));
        collateral.transfer(makeAddr("random"), tokenId, amount);

        // Testing non-existing tokenId where the balance will be 0
        uint256 nonExistingTokenId = 1337;
        vm.expectRevert(abi.encodeWithSelector(ERC6909_Transfer_InsufficientBalance.selector, self, nonExistingTokenId));
        collateral.transfer(receiver, nonExistingTokenId, amount);
    }

    function testTransferFrom() public {
        address operator = makeAddr("operator");
        address delegate = makeAddr("delegate");
        address receiver = makeAddr("receiver");

        uint256 amount = 32;
        string memory URI = "some/random/URI";
        uint256 tokenId = collateral.mint(self, URI, amount);

        uint256 sentAmount = amount / 2; // 16

        // Caller is neither operator, nor has allowance
        vm.expectRevert(abi.encodeWithSelector(ERC6909_TransferFrom_InsufficientAllowance.selector, delegate, tokenId));
        vm.prank(delegate);
        bool isSuccessful = collateral.transferFrom(self, receiver, tokenId, sentAmount);
        assertFalse(isSuccessful);

        assertEq(collateral.balanceOf(receiver, tokenId), 0);
        assertEq(collateral.balanceOf(self, tokenId), amount);

        // Caller is an operator and does not have allowance
        collateral.setOperator(operator, true);
        assertEq(collateral.allowance(self, operator, tokenId), 0);

        vm.prank(operator);
        isSuccessful = collateral.transferFrom(self, receiver, tokenId, sentAmount);
        assertTrue(isSuccessful);

        uint256 remainingBalance = amount - sentAmount; // 16
        assertEq(collateral.balanceOf(receiver, tokenId), sentAmount);
        assertEq(collateral.balanceOf(self, tokenId), remainingBalance);

        // Caller has allowance and it is not an operator
        uint256 receiverBalance = collateral.balanceOf(receiver, tokenId);
        uint256 allowance = remainingBalance;
        sentAmount = remainingBalance / 2; // 8
        collateral.approve(delegate, tokenId, allowance);

        assertFalse(collateral.isOperator(self, delegate));
        assertEq(collateral.allowance(self, delegate, tokenId), allowance);

        vm.prank(delegate);
        isSuccessful = collateral.transferFrom(self, receiver, tokenId, sentAmount);

        remainingBalance = remainingBalance - sentAmount; // 8

        assertTrue(isSuccessful);
        assertEq(collateral.balanceOf(receiver, tokenId), receiverBalance + sentAmount);
        assertEq(collateral.balanceOf(self, tokenId), remainingBalance);
        assertEq(collateral.allowance(self, delegate, tokenId), allowance - sentAmount);

        // Caller is actually the owner
        receiverBalance = collateral.balanceOf(receiver, tokenId);

        isSuccessful = collateral.transferFrom(self, receiver, tokenId, remainingBalance);

        assertTrue(isSuccessful);
        assertEq(collateral.balanceOf(receiver, tokenId), receiverBalance + remainingBalance);
        assertEq(collateral.balanceOf(self, tokenId), 0);
    }

    function testApprovals(address delegate, uint256 tokenId, uint256 amount) public {
        assertEq(collateral.allowance(self, delegate, tokenId), 0);

        bool isSuccessful = collateral.approve(delegate, tokenId, amount);
        assertTrue(isSuccessful);
        assertEq(collateral.allowance(self, delegate, tokenId), amount);

        isSuccessful = collateral.approve(delegate, tokenId, amount);
        assertTrue(isSuccessful);
        assertEq(collateral.allowance(self, delegate, tokenId), amount);

        uint256 newAllowance = amount + 1;
        isSuccessful = collateral.approve(delegate, tokenId, newAllowance);
        assertTrue(isSuccessful);
        assertEq(collateral.allowance(self, delegate, tokenId), newAllowance);
    }
}
