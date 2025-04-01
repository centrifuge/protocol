// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";
import {RestrictedTransfers} from "src/vaults/token/RestrictedTransfers.sol";
import {IERC165} from "src/vaults/interfaces/IERC7575.sol";
import "forge-std/Test.sol";
import {MockRoot} from "test/common/mocks/MockRoot.sol";

contract RestrictedTransfersTest is Test {
    MockRoot root;
    CentrifugeToken token;
    RestrictedTransfers restrictionManager;

    function setUp() public {
        root = new MockRoot();
        token = new CentrifugeToken(18);
        restrictionManager = new RestrictedTransfers(address(root), address(this));
        token.file("hook", address(restrictionManager));
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("RestrictedTransfers/invalid-update"));
        restrictionManager.updateRestriction(address(token), abi.encodePacked(uint8(0)));
    }

    function testAddMember(uint64 validUntil) public {
        vm.assume(validUntil >= block.timestamp);

        vm.expectRevert("RestrictedTransfers/invalid-valid-until");
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
        vm.expectRevert("RestrictedTransfers/cannot-freeze-zero-address");
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
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
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
