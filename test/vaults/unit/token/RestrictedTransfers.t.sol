// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {RestrictedTransfers} from "src/hooks/RestrictedTransfers.sol";
import {IERC165} from "src/vaults/interfaces/IERC7575.sol";
import "forge-std/Test.sol";
import {MockRoot} from "test/common/mocks/MockRoot.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {IRestrictedTransfers} from "src/hooks/interfaces/IRestrictedTransfers.sol";
import {IFreezable} from "src/hooks/interfaces/IFreezable.sol";

contract RestrictedTransfersTest is Test {
    MockRoot root;
    ShareToken token;
    RestrictedTransfers restrictedTransfers;

    function setUp() public {
        root = new MockRoot();
        token = new ShareToken(18);
        restrictedTransfers = new RestrictedTransfers(address(root), address(this));
        token.file("hook", address(restrictedTransfers));
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(IHook.InvalidUpdate.selector);
        restrictedTransfers.updateRestriction(address(token), abi.encodePacked(uint8(0)));
    }

    function testAddMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        vm.expectRevert(IRestrictedTransfers.InvalidValidUntil.selector);
        restrictedTransfers.updateMember(address(token), address(this), uint64(block.timestamp - 1));

        restrictedTransfers.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictedTransfers.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testIsMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        restrictedTransfers.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictedTransfers.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testFreeze() public {
        restrictedTransfers.freeze(address(token), address(this));
        assertEq(restrictedTransfers.isFrozen(address(token), address(this)), true);
    }

    function testFreezingZeroAddress() public {
        vm.expectRevert(IFreezable.CannotFreezeZeroAddress.selector);
        restrictedTransfers.freeze(address(token), address(0));
        assertEq(restrictedTransfers.isFrozen(address(token), address(0)), false);
    }

    function testAddMemberAndFreeze(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        restrictedTransfers.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictedTransfers.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(restrictedTransfers.isFrozen(address(token), address(this)), false);

        restrictedTransfers.freeze(address(token), address(this));
        (_isMember, _validUntil) = restrictedTransfers.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(restrictedTransfers.isFrozen(address(token), address(this)), true);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 hook = 0xad4e9d84;

        vm.assume(unsupportedInterfaceId != erc165 && unsupportedInterfaceId != hook);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IHook).interfaceId, hook);

        assertEq(restrictedTransfers.supportsInterface(erc165), true);
        assertEq(restrictedTransfers.supportsInterface(hook), true);

        assertEq(restrictedTransfers.supportsInterface(unsupportedInterfaceId), false);
    }
}
