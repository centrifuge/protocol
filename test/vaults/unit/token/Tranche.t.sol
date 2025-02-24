// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/vaults/interfaces/IERC7575.sol";
import "src/vaults/interfaces/IERC7540.sol";
import {Tranche} from "src/vaults/token/Tranche.sol";
import {MockRoot} from "test/vaults/mocks/MockRoot.sol";
import {MockRestrictionManager} from "test/vaults/mocks/MockRestrictionManager.sol";
import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

interface ERC20Like {
    function balanceOf(address) external view returns (uint256);
}

contract TrancheTest is Test, GasSnapshot {
    Tranche token;
    MockRestrictionManager restrictionManager;

    address self;
    address escrow = makeAddr("escrow");
    address targetUser = makeAddr("targetUser");
    address randomUser = makeAddr("random");
    uint64 validUntil = uint64(block.timestamp + 7 days);

    function setUp() public {
        self = address(this);
        token = new Tranche(18);
        token.file("name", "Some Token");
        token.file("symbol", "ST");

        restrictionManager = new MockRestrictionManager(address(new MockRoot()), address(this));
        token.file("hook", address(restrictionManager));
    }

    // --- Admnistration ---
    function testFile(address asset, address vault) public {
        address hook = makeAddr("hook");

        // fail: unrecognized param
        vm.expectRevert(bytes("Tranche/file-unrecognized-param"));
        token.file("random", hook);

        // success
        token.file("hook", hook);
        assertEq(address(token.hook()), hook);

        token.updateVault(asset, vault);
        assertEq(address(token.vault(asset)), vault);

        // remove self from wards
        token.deny(self);

        // auth fail
        vm.expectRevert(bytes("Tranche/not-authorized"));
        token.file("hook", hook);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.updateVault(asset, vault);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 erc7575Share = 0xf815c03d;

        vm.assume(unsupportedInterfaceId != erc165 && unsupportedInterfaceId != erc7575Share);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IERC7575Share).interfaceId, erc7575Share);

        assertEq(token.supportsInterface(erc165), true);
        assertEq(token.supportsInterface(erc7575Share), true);

        assertEq(token.supportsInterface(unsupportedInterfaceId), false);
    }

    // --- erc1404 checks ---
    function testERC1404Support() public view {
        assertEq(token.messageForTransferRestriction(0), "transfer-allowed");
        assertEq(token.messageForTransferRestriction(1), "transfer-blocked");
    }

    // --- RestrictionManager ---
    // transferFrom
    function testTransferFrom(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max / 2);

        restrictionManager.updateMember(address(token), self, uint64(validUntil));
        token.mint(self, amount * 2);

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transferFrom(self, targetUser, amount);
        assertEq(token.balanceOf(targetUser), 0);

        restrictionManager.updateMember(address(token), targetUser, uint64(validUntil));
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), targetUser);
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);

        restrictionManager.freeze(address(token), self);
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transferFrom(self, targetUser, amount);
        assertEq(token.balanceOf(targetUser), 0);

        restrictionManager.unfreeze(address(token), self);
        restrictionManager.freeze(address(token), targetUser);
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transferFrom(self, targetUser, amount);
        assertEq(token.balanceOf(targetUser), 0);

        restrictionManager.unfreeze(address(token), targetUser);
        snapStart("Tranche_transferFrom");
        token.transferFrom(self, targetUser, amount);
        snapEnd();
        assertEq(token.balanceOf(targetUser), amount);
        afterTransferAssumptions(self, targetUser, amount);

        vm.warp(validUntil + 1);
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transferFrom(self, targetUser, amount);
    }

    function testTransferFromTokensWithApproval(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        address sender = makeAddr("sender");
        restrictionManager.updateMember(address(token), sender, uint64(validUntil));
        token.mint(sender, amount);

        restrictionManager.updateMember(address(token), targetUser, uint64(validUntil));

        vm.expectRevert(IERC20.InsufficientAllowance.selector);
        token.transferFrom(sender, targetUser, amount);

        vm.prank(sender);
        token.approve(self, amount);
        token.transferFrom(sender, targetUser, amount);
        assertEq(token.balanceOf(targetUser), amount);
        assertEq(token.balanceOf(sender), 0);
    }

    // transfer
    function testTransfer(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max / 2);

        restrictionManager.updateMember(address(token), self, uint64(validUntil));
        token.mint(self, amount * 2);

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transfer(targetUser, amount);
        assertEq(token.balanceOf(targetUser), 0);

        restrictionManager.updateMember(address(token), targetUser, uint64(validUntil));
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), targetUser);
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);

        restrictionManager.freeze(address(token), self);
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transfer(targetUser, amount);
        assertEq(token.balanceOf(targetUser), 0);

        restrictionManager.unfreeze(address(token), self);
        token.transfer(targetUser, amount);
        assertEq(token.balanceOf(targetUser), amount);
        afterTransferAssumptions(self, targetUser, amount);

        vm.warp(validUntil + 1);
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.transfer(targetUser, amount);
    }

    // auth transfer
    function testAuthTransferFrom(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max);
        address sourceUser = makeAddr("sourceUser");
        restrictionManager.updateMember(address(token), sourceUser, uint64(validUntil));
        token.mint(sourceUser, amount);

        vm.prank(address(2));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        token.authTransferFrom(sourceUser, sourceUser, self, amount);
        assertEq(token.balanceOf(sourceUser), amount);
        assertEq(token.balanceOf(self), 0);

        token.authTransferFrom(sourceUser, sourceUser, self, amount);
        assertEq(token.balanceOf(sourceUser), 0);
        assertEq(token.balanceOf(self), amount);
    }

    // mint
    function testMintTokensToMemberWorks(uint256 amount) public {
        amount = bound(amount, 0, type(uint128).max / 2);

        // mint fails -> self not a member
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.mint(targetUser, amount);

        restrictionManager.updateMember(address(token), targetUser, uint64(validUntil));
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), targetUser);
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);

        token.mint(targetUser, amount);
        assertEq(token.balanceOf(targetUser), amount);
        afterTransferAssumptions(address(0), targetUser, amount);

        vm.warp(validUntil + 1);

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        token.mint(targetUser, amount);
    }

    function afterTransferAssumptions(address from, address to, uint256 value) internal view {
        assertEq(restrictionManager.values_address("onERC20Transfer_from"), from);
        assertEq(restrictionManager.values_address("onERC20Transfer_to"), to);
        assertEq(restrictionManager.values_uint256("onERC20Transfer_value"), value);
    }
}
