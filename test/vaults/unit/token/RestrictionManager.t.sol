// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

import {Tranche} from "src/token/Tranche.sol";
import {MockRoot} from "test/mocks/MockRoot.sol";
import {IHook} from "src/interfaces/token/IHook.sol";
import {RestrictionManager} from "src/token/RestrictionManager.sol";
import {RestrictionUpdate} from "src/interfaces/token/IRestrictionManager.sol";
import {MessagesLib} from "src/libraries/MessagesLib.sol";
import {IERC165} from "src/interfaces/IERC7575.sol";
import "forge-std/Test.sol";

contract RestrictionManagerTest is Test {
    MockRoot root;
    Tranche token;
    RestrictionManager restrictionManager;

    function setUp() public {
        root = new MockRoot();
        token = new Tranche(18);
        restrictionManager = new RestrictionManager(address(root), address(this));
        token.file("hook", address(restrictionManager));
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("RestrictionManager/invalid-update"));
        restrictionManager.updateRestriction(address(token), abi.encodePacked(uint8(RestrictionUpdate.Invalid)));
    }

    function testAddMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        vm.expectRevert("RestrictionManager/invalid-valid-until");
        restrictionManager.updateMember(address(token), address(this), uint64(block.timestamp - 1));

        restrictionManager.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testIsMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        restrictionManager.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
    }

    function testFreeze() public {
        restrictionManager.freeze(address(token), address(this));
        assertEq(restrictionManager.isFrozen(address(token), address(this)), true);
    }

    function testFreezingZeroAddress() public {
        vm.expectRevert("RestrictionManager/cannot-freeze-zero-address");
        restrictionManager.freeze(address(token), address(0));
        assertEq(restrictionManager.isFrozen(address(token), address(0)), false);
    }

    function testAddMemberAndFreeze(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        restrictionManager.updateMember(address(token), address(this), validUntil);
        (bool _isMember, uint64 _validUntil) = restrictionManager.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(restrictionManager.isFrozen(address(token), address(this)), false);

        restrictionManager.freeze(address(token), address(this));
        (_isMember, _validUntil) = restrictionManager.isMember(address(token), address(this));
        assertTrue(_isMember);
        assertEq(_validUntil, validUntil);
        assertEq(restrictionManager.isFrozen(address(token), address(this)), true);
    }

    // --- erc165 checks ---
    function testERC165Support(bytes4 unsupportedInterfaceId) public {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 hook = 0xad4e9d84;

        vm.assume(unsupportedInterfaceId != erc165 && unsupportedInterfaceId != hook);

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IHook).interfaceId, hook);

        assertEq(restrictionManager.supportsInterface(erc165), true);
        assertEq(restrictionManager.supportsInterface(hook), true);

        assertEq(restrictionManager.supportsInterface(unsupportedInterfaceId), false);
    }
}
