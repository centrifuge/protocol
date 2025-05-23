// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {MockRoot} from "test/common/mocks/MockRoot.sol";

import {IERC165} from "src/misc/interfaces/IERC7575.sol";

import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {IHook} from "src/common/interfaces/IHook.sol";

import {FullRestrictions} from "src/hooks/FullRestrictions.sol";
import {IMemberlist} from "src/hooks/interfaces/IMemberlist.sol";
import {IFreezable} from "src/hooks/interfaces/IFreezable.sol";

contract FullRestrictionsTest is Test {
    MockRoot root;
    ShareToken token;
    FullRestrictions fullRestrictionsHook;

    function setUp() public {
        root = new MockRoot();
        token = new ShareToken(18);
        fullRestrictionsHook = new FullRestrictions(address(root), address(this));
        token.file("hook", address(fullRestrictionsHook));
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(IHook.InvalidUpdate.selector);
        fullRestrictionsHook.updateRestriction(address(token), abi.encodePacked(uint8(0)));
    }

    function testAddMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        vm.expectRevert(IMemberlist.InvalidValidUntil.selector);
        fullRestrictionsHook.updateMember(address(token), address(this), uint64(block.timestamp - 1));

        fullRestrictionsHook.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = fullRestrictionsHook.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testIsMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        fullRestrictionsHook.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = fullRestrictionsHook.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testFreeze() public {
        fullRestrictionsHook.freeze(address(token), address(this));
        assertEq(fullRestrictionsHook.isFrozen(address(token), address(this)), true);
    }

    function testFreezingZeroAddress() public {
        vm.expectRevert(IFreezable.CannotFreezeZeroAddress.selector);
        fullRestrictionsHook.freeze(address(token), address(0));
        assertEq(fullRestrictionsHook.isFrozen(address(token), address(0)), false);
    }

    function testAddMemberAndFreeze(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        fullRestrictionsHook.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = fullRestrictionsHook.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(fullRestrictionsHook.isFrozen(address(token), address(this)), false);

        fullRestrictionsHook.freeze(address(token), address(this));
        (_isMember, _validUntil) = fullRestrictionsHook.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(fullRestrictionsHook.isFrozen(address(token), address(this)), true);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 hook = 0xad4e9d84;

        vm.assume(unsupportedInterfaceId != erc165 && unsupportedInterfaceId != hook);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IHook).interfaceId, hook);

        assertEq(fullRestrictionsHook.supportsInterface(erc165), true);
        assertEq(fullRestrictionsHook.supportsInterface(hook), true);

        assertEq(fullRestrictionsHook.supportsInterface(unsupportedInterfaceId), false);
    }
}
