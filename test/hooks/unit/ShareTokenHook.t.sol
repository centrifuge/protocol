// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../../../src/misc/libraries/BitmapLib.sol";

import {MockEscrowProvider} from "../../core/mocks/MockEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {IFreezable} from "../../../src/token/hooks/interfaces/IFreezable.sol";
import {IMemberlist} from "../../../src/token/hooks/interfaces/IMemberlist.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";
import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {MockVaultRegistry} from "../mocks/MockVaultRegistry.sol";

import "forge-std/Test.sol";

import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../../src/token/interfaces/IRoleHook.sol";

contract MockRoot {
    mapping(address => bool) public endorsed;

    function setEndorsed(address user, bool status) external {
        endorsed[user] = status;
    }
}

/// @dev Serves as the hook's spoke registry: vault lookups answer unregistered unless a test sets them.
contract MockSpoke is MockVaultRegistry {}

contract MockShareToken {
    mapping(address => bytes16) public hookDataOf;

    function setHookData(address user, bytes16 data) external {
        hookDataOf[user] = data;
    }
}

contract MockEscrow {
    PoolId public immutable poolId;

    constructor(PoolId poolId_) {
        poolId = poolId_;
    }
}

contract TestableShareTokenHook is ShareTokenHook {
    using BitmapLib for *;

    function setBit(address token, address user, uint8 bit, bool value) external {
        _setHookBit(token, user, bit, value);
    }

    function getBit(address token, address user, uint8 bit) external view returns (bool) {
        return _getHookBit(token, user, bit);
    }

    /// @dev A freeze-only policy: no role asks for membership.
    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address escrowProvider_
    )
        ShareTokenHook(
            root_,
            envoy_,
            spokeRegistry_,
            spoke_,
            crosschainSource_,
            deployer,
            escrowProvider_,
            HookPolicies.freezeOnly()
        )
    {}
}

contract ShareTokenHookTestBase is Test {
    using UpdateRestrictionMessageLib for *;
    using BitmapLib for *;
    using CastLib for *;

    //----------------------------------------------------------------------------------------------
    // CONSTANTS & STATE
    //----------------------------------------------------------------------------------------------

    TestableShareTokenHook hook;
    MockRoot mockRoot;
    MockSpoke mockSpoke;
    MockShareToken mockShareToken;
    MockEscrow mockEscrow;
    MockEscrowProvider mockEscrowProvider;

    address deployer = makeAddr("deployer");
    address envoy = makeAddr("envoy");
    address crosschainSource = makeAddr("crosschainSource");
    address spoke = makeAddr("spoke");
    address escrow;
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address endorsedUser = makeAddr("endorsedUser");

    PoolId constant TEST_POOL_ID = PoolId.wrap(1);

    uint64 constant FUTURE_TIMESTAMP = type(uint64).max;
    uint64 constant EXACT_BOUNDARY_TIMESTAMP = 1000;
    uint64 pastTimestamp = 1;

    //----------------------------------------------------------------------------------------------
    // SETUP
    //----------------------------------------------------------------------------------------------

    function setUp() public virtual {
        mockRoot = new MockRoot();
        mockSpoke = new MockSpoke();

        // Create a real mock escrow
        mockEscrow = new MockEscrow(TEST_POOL_ID);
        escrow = address(mockEscrow);

        // Create mock escrow provider and configure it
        mockEscrowProvider = new MockEscrowProvider();
        mockEscrowProvider.setEscrow(TEST_POOL_ID, escrow);

        vm.prank(deployer);
        hook = new TestableShareTokenHook(
            address(mockRoot), envoy, address(mockSpoke), spoke, crosschainSource, deployer, address(mockEscrowProvider)
        );

        mockShareToken = new MockShareToken();

        pastTimestamp = uint64(block.timestamp - 1);

        _setEndorsedUsers();
    }

    //----------------------------------------------------------------------------------------------
    // HELPER FUNCTIONS
    //----------------------------------------------------------------------------------------------

    function _setEndorsedUsers() internal {
        mockRoot.setEndorsed(endorsedUser, true);
        mockRoot.setEndorsed(spoke, true);
        mockRoot.setEndorsed(crosschainSource, true);
    }

    function _freezeUser(address user) internal {
        vm.prank(deployer);
        hook.freeze(address(mockShareToken), user);
    }

    function _unfreezeUser(address user) internal {
        vm.prank(deployer);
        hook.unfreeze(address(mockShareToken), user);
    }

    function _updateMemberValidUntil(address user, uint64 validUntil) internal {
        vm.prank(deployer);
        hook.updateMember(address(mockShareToken), user, validUntil);
    }

    function _createHookDataWithFreezeBit(bool frozen) internal pure returns (HookData memory) {
        HookData memory hookData;
        if (frozen) {
            hookData.from = bytes16(uint128(1)); // Set freeze bit
        }
        return hookData;
    }

    function _createHookDataWithMembership(uint64 sourceValidUntil, uint64 targetValidUntil)
        internal
        pure
        returns (HookData memory)
    {
        HookData memory hookData;
        hookData.from = bytes16(uint128(sourceValidUntil) << 64);
        hookData.to = bytes16(uint128(targetValidUntil) << 64);
        return hookData;
    }
}

contract ShareTokenHookTestConstructor is ShareTokenHookTestBase {
    function testConstructor() public view {
        assertEq(address(hook.root()), address(mockRoot));
        assertEq(address(hook.spoke()), spoke);
        assertEq(hook.crosschainSource(), crosschainSource);
        assertEq(hook.FREEZE_BIT(), 0);
    }

    function testConstructorInvalidInputs() public {
        vm.expectRevert(IShareTokenHook.InvalidInputs.selector);
        vm.prank(deployer);
        new TestableShareTokenHook(
            address(mockRoot),
            envoy,
            address(mockSpoke),
            spoke,
            spoke, // Same as spoke - should fail
            deployer,
            address(mockEscrowProvider)
        );
    }
}

contract ShareTokenHookTestTransferTypes is ShareTokenHookTestBase {
    function testLegClassifiesEveryMovement() public view {
        // A mint to a holder, an endorsed contract or the spoke is an issuance
        assertEq(uint8(hook.leg(address(0), user1)), uint8(IShareTokenHook.Kind.Mint));
        assertEq(uint8(hook.leg(address(0), endorsedUser)), uint8(IShareTokenHook.Kind.Mint));
        // A mint into an escrow (a deposit fulfillment) or to the crosschain source is a plain transfer
        assertEq(uint8(hook.leg(address(0), escrow)), uint8(IShareTokenHook.Kind.Transfer));
        assertEq(uint8(hook.leg(address(0), crosschainSource)), uint8(IShareTokenHook.Kind.Transfer));

        // Shares leaving an escrow for anyone are a deposit claim
        assertEq(uint8(hook.leg(escrow, user1)), uint8(IShareTokenHook.Kind.Release));
        assertEq(uint8(hook.leg(escrow, endorsedUser)), uint8(IShareTokenHook.Kind.Release));
        assertEq(uint8(hook.leg(escrow, address(0))), uint8(IShareTokenHook.Kind.Burn));

        // The spoke's burn is the fulfillment of a redemption, any other burn is a holder's own
        assertEq(uint8(hook.leg(spoke, address(0))), uint8(IShareTokenHook.Kind.Fulfill));
        assertEq(uint8(hook.leg(user1, address(0))), uint8(IShareTokenHook.Kind.Burn));
        assertEq(
            uint8(hook.leg(crosschainSource, address(0))),
            uint8(IShareTokenHook.Kind.Transfer),
            "the source never burns"
        );

        // A holder to a holder, a chain id or an escrow, and a receipt from the crosschain source, are transfers
        assertEq(uint8(hook.leg(user1, user2)), uint8(IShareTokenHook.Kind.Transfer));
        assertEq(uint8(hook.leg(user1, endorsedUser)), uint8(IShareTokenHook.Kind.Transfer));
        assertEq(uint8(hook.leg(user1, escrow)), uint8(IShareTokenHook.Kind.Transfer));
        assertEq(uint8(hook.leg(user1, address(uint160(1)))), uint8(IShareTokenHook.Kind.Transfer));
        assertEq(uint8(hook.leg(crosschainSource, user1)), uint8(IShareTokenHook.Kind.Transfer));
    }

    function testFreezeSuccess() public {
        _freezeUser(user1);

        assertTrue(hook.isFrozen(address(mockShareToken), user1));

        // Check that hook data was set correctly
        assertTrue(BitmapLib.getBit(uint128(mockShareToken.hookDataOf(user1)), 0)); // FREEZE_BIT = 0
    }

    function testFreezeZeroAddress() public {
        vm.expectRevert(IFreezable.CannotFreezeZeroAddress.selector);
        vm.prank(deployer);
        hook.freeze(address(mockShareToken), address(0));
    }

    function testFreezeEndorsedUser() public {
        vm.expectRevert(IFreezable.EndorsedUserCannotBeFrozen.selector);
        vm.prank(deployer);
        hook.freeze(address(mockShareToken), endorsedUser);
    }

    function testFreezeEscrow() public {
        assertFalse(mockRoot.endorsed(escrow));

        vm.expectRevert(IFreezable.EndorsedUserCannotBeFrozen.selector);
        vm.prank(deployer);
        hook.freeze(address(mockShareToken), escrow);
    }

    function testFreezeUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(user1);
        hook.freeze(address(mockShareToken), user2);
    }

    function testUnfreezeSuccess() public {
        // First freeze the user
        _freezeUser(user1);
        assertTrue(hook.isFrozen(address(mockShareToken), user1));

        // Then unfreeze
        _unfreezeUser(user1);
        assertFalse(hook.isFrozen(address(mockShareToken), user1));
    }

    function testUnfreezeUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(user1);
        hook.unfreeze(address(mockShareToken), user2);
    }

    function testFreezeUnfreezePattern() public {
        assertFalse(hook.isFrozen(address(mockShareToken), user1));

        _freezeUser(user1);
        assertTrue(hook.isFrozen(address(mockShareToken), user1));

        _unfreezeUser(user1);
        assertFalse(hook.isFrozen(address(mockShareToken), user1));
    }
}

contract ShareTokenHookTestMember is ShareTokenHookTestBase {
    function testUpdateMemberSuccess() public {
        _updateMemberValidUntil(user1, FUTURE_TIMESTAMP);

        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(validUntil, FUTURE_TIMESTAMP);
    }

    function testUpdateMemberInvalidValidUntil() public {
        // Try to set a validUntil timestamp that's in the past
        vm.expectRevert(IMemberlist.InvalidValidUntil.selector);
        vm.prank(deployer);
        hook.updateMember(address(mockShareToken), user1, pastTimestamp);
    }

    function testUpdateMemberExactBoundaryTimestamp() public {
        // Test exact boundary condition - current block timestamp should be valid
        vm.warp(EXACT_BOUNDARY_TIMESTAMP);

        _updateMemberValidUntil(user1, EXACT_BOUNDARY_TIMESTAMP);

        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(validUntil, EXACT_BOUNDARY_TIMESTAMP);
    }

    function testUpdateMemberEndorsedUser() public {
        vm.expectRevert(IMemberlist.EndorsedUserCannotBeUpdated.selector);
        vm.prank(deployer);
        hook.updateMember(address(mockShareToken), endorsedUser, FUTURE_TIMESTAMP);
    }

    function testUpdateMemberEscrow() public {
        assertFalse(mockRoot.endorsed(escrow));
        assertTrue(hook.isEscrow(escrow));

        _updateMemberValidUntil(escrow, FUTURE_TIMESTAMP);

        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), escrow);
        assertTrue(isValid);
        assertEq(validUntil, FUTURE_TIMESTAMP);
    }

    /// @dev Bits 1 to 63 of the hook data belong to a hook extension, so a membership update replaces only the
    ///      valid-until bits and leaves the freeze bit and everything below it alone.
    function testUpdateMemberKeepsTheBitsItDoesNotOwn() public {
        mockShareToken.setHookData(user1, bytes16(type(uint128).max));

        _updateMemberValidUntil(user1, FUTURE_TIMESTAMP);

        assertEq(mockShareToken.hookDataOf(user1), bytes16((uint128(FUTURE_TIMESTAMP) << 64) | type(uint64).max));
    }

    /// @dev The helper a hook extension uses for its own flags: one bit changes and nothing else does, and the
    ///      valid-until bits are out of reach.
    function testSetHookBitChangesOnlyThatBit() public {
        mockShareToken.setHookData(user1, bytes16((uint128(FUTURE_TIMESTAMP) << 64) | uint128(0x10)));

        hook.setBit(address(mockShareToken), user1, 3, true);
        assertEq(mockShareToken.hookDataOf(user1), bytes16((uint128(FUTURE_TIMESTAMP) << 64) | uint128(0x18)));
        assertTrue(hook.getBit(address(mockShareToken), user1, 3));
        assertFalse(hook.getBit(address(mockShareToken), user1, 5));

        hook.setBit(address(mockShareToken), user1, 4, false);
        assertEq(mockShareToken.hookDataOf(user1), bytes16((uint128(FUTURE_TIMESTAMP) << 64) | uint128(0x08)));

        vm.expectRevert(IShareTokenHook.InvalidHookBit.selector);
        hook.setBit(address(mockShareToken), user1, 64, true);
        vm.expectRevert(IShareTokenHook.InvalidHookBit.selector);
        hook.getBit(address(mockShareToken), user1, 64);
    }

    function testFreezeAndUnfreezeKeepTheBitsTheyDoNotOwn() public {
        uint128 extra = uint128(0xA5A5) << 1;
        mockShareToken.setHookData(user1, bytes16((uint128(FUTURE_TIMESTAMP) << 64) | extra));

        _freezeUser(user1);
        assertEq(mockShareToken.hookDataOf(user1), bytes16((uint128(FUTURE_TIMESTAMP) << 64) | extra | 1));

        _unfreezeUser(user1);
        assertEq(mockShareToken.hookDataOf(user1), bytes16((uint128(FUTURE_TIMESTAMP) << 64) | extra));
    }

    function testUpdateMemberUnauthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(user1);
        hook.updateMember(address(mockShareToken), user2, FUTURE_TIMESTAMP);
    }

    function testUpdateMemberPreservesFreezeStatus() public {
        // First freeze the user
        _freezeUser(user1);
        assertTrue(hook.isFrozen(address(mockShareToken), user1));

        // Update member status
        _updateMemberValidUntil(user1, FUTURE_TIMESTAMP);

        // Check that freeze status is preserved
        assertTrue(hook.isFrozen(address(mockShareToken), user1));
        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(validUntil, FUTURE_TIMESTAMP);
    }

    function testMembershipStatus() public {
        // Initially not a member
        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), user1);
        assertFalse(isValid);
        assertEq(validUntil, 0);

        // Set as member
        _updateMemberValidUntil(user1, FUTURE_TIMESTAMP);

        (isValid, validUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(validUntil, FUTURE_TIMESTAMP);
    }

    function testTransferChecksFreezeOnBothEnds() public view {
        HookData memory hookData;
        assertTrue(hook.checkERC20Transfer(user1, user2, 1, hookData));

        hookData = _createHookDataWithFreezeBit(true);
        assertFalse(hook.checkERC20Transfer(user1, user2, 1, hookData), "frozen source");

        hookData.from = bytes16(0);
        hookData.to = bytes16(uint128(1));
        assertFalse(hook.checkERC20Transfer(user1, user2, 1, hookData), "frozen target");
    }
}

contract ShareTokenHookTestUpdateRestriction is ShareTokenHookTestBase {
    function testUpdateRestrictionMember() public {
        UpdateRestrictionMessageLib.UpdateRestrictionMember memory memberUpdate =
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: bytes32(bytes20(user1)), validUntil: FUTURE_TIMESTAMP
            });

        bytes memory payload = UpdateRestrictionMessageLib.serialize(memberUpdate);

        vm.prank(deployer);
        hook.updateRestriction(address(mockShareToken), payload);

        (bool isValid, uint64 validUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(validUntil, FUTURE_TIMESTAMP);
    }

    function testUpdateRestrictionFreeze() public {
        UpdateRestrictionMessageLib.UpdateRestrictionFreeze memory freezeUpdate =
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze({user: bytes32(bytes20(user1))});

        bytes memory payload = UpdateRestrictionMessageLib.serialize(freezeUpdate);

        vm.prank(deployer);
        hook.updateRestriction(address(mockShareToken), payload);

        assertTrue(hook.isFrozen(address(mockShareToken), user1));
    }

    function testUpdateRestrictionUnfreeze() public {
        // First freeze the user
        _freezeUser(user1);
        assertTrue(hook.isFrozen(address(mockShareToken), user1));

        UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze memory unfreezeUpdate =
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze({user: bytes32(bytes20(user1))});

        bytes memory payload = UpdateRestrictionMessageLib.serialize(unfreezeUpdate);

        vm.prank(deployer);
        hook.updateRestriction(address(mockShareToken), payload);

        assertFalse(hook.isFrozen(address(mockShareToken), user1));
    }

    function testUpdateRestrictionInvalidUpdate() public {
        // Create an empty payload that should trigger InvalidUpdate error
        bytes memory invalidPayload = "";

        vm.expectRevert();
        vm.prank(deployer);
        hook.updateRestriction(address(mockShareToken), invalidPayload);
    }

    function testUpdateRestrictionUnauthorized() public {
        UpdateRestrictionMessageLib.UpdateRestrictionMember memory memberUpdate =
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: bytes32(bytes20(user1)), validUntil: FUTURE_TIMESTAMP
            });

        bytes memory payload = UpdateRestrictionMessageLib.serialize(memberUpdate);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(user1);
        hook.updateRestriction(address(mockShareToken), payload);
    }
}

contract ShareTokenHookTestERC20Hook is ShareTokenHookTestBase {
    function testOnERC20TransferSuccess() public {
        HookData memory hookData;

        bytes4 result = hook.onERC20Transfer(user1, user2, 100, hookData);
        assertEq(result, ITransferHook.onERC20Transfer.selector);
    }

    function testOnERC20TransferBlocked() public {
        HookData memory hookData = _createHookDataWithFreezeBit(true);

        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        hook.onERC20Transfer(user1, user2, 100, hookData);
    }

    function testOnERC20AuthTransfer() public view {
        HookData memory hookData;

        bytes4 result = hook.onERC20AuthTransfer(user1, user2, address(0), 100, hookData);
        assertEq(result, ITransferHook.onERC20AuthTransfer.selector);
    }

    function testCheckERC20TransferValidation() public view {
        HookData memory hookData;

        // Should pass when not frozen
        assertTrue(hook.checkERC20Transfer(user1, user2, 100, hookData));

        // Should fail when source is frozen
        hookData = _createHookDataWithFreezeBit(true);
        assertFalse(hook.checkERC20Transfer(user1, user2, 100, hookData));
    }
}

contract ShareTokenHookTestInterfaceSupport is ShareTokenHookTestBase {
    function testSupportsInterface() public view {
        assertTrue(hook.supportsInterface(type(ITransferHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IRoleHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(bytes4(0)));
    }
}

contract ShareTokenHookTestEvents is ShareTokenHookTestBase {
    function testFreezeEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IFreezable.Freeze(address(mockShareToken), user1);

        _freezeUser(user1);
    }

    function testUnfreezeEvent() public {
        _freezeUser(user1);

        vm.expectEmit(true, true, false, false);
        emit IFreezable.Unfreeze(address(mockShareToken), user1);

        _unfreezeUser(user1);
    }

    function testUpdateMemberEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IMemberlist.UpdateMember(address(mockShareToken), user1, FUTURE_TIMESTAMP);

        _updateMemberValidUntil(user1, FUTURE_TIMESTAMP);
    }
}

contract ShareTokenHookTestTrustedCall is ShareTokenHookTestBase {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    function testUnknownTrustedCall() public {
        // Create payload with invalid enum value
        bytes memory invalidPayload = abi.encode(SC_1.raw(), uint8(255), bytes32(0), false);

        vm.expectRevert(IShareTokenHook.UnknownTrustedCall.selector);
        vm.prank(envoy);
        hook.fromHub(POOL_A, invalidPayload);
    }

    function testFromHubUpdateManagerSuccess() public {
        // Mock the share token to exist
        vm.mockCall(
            address(mockSpoke),
            abi.encodeWithSelector(bytes4(keccak256("shareToken(uint64,bytes16)")), POOL_A.raw(), SC_1.raw()),
            abi.encode(address(mockShareToken))
        );

        address managerAddress = makeAddr("manager");
        bytes memory payload = abi.encode(
            SC_1.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.prank(envoy);
        vm.expectEmit();
        emit IShareTokenHook.UpdateHookManager(address(mockShareToken), managerAddress, true);
        hook.fromHub(POOL_A, payload);

        assertTrue(hook.manager(address(mockShareToken), managerAddress));
    }

    function testFromHubUpdateManagerDisable() public {
        // Mock the share token to exist
        vm.mockCall(
            address(mockSpoke),
            abi.encodeWithSelector(bytes4(keccak256("shareToken(uint64,bytes16)")), POOL_A.raw(), SC_1.raw()),
            abi.encode(address(mockShareToken))
        );

        address managerAddress = makeAddr("manager");

        // First enable
        bytes memory enablePayload = abi.encode(
            SC_1.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );
        vm.prank(envoy);
        vm.expectEmit();
        emit IShareTokenHook.UpdateHookManager(address(mockShareToken), managerAddress, true);
        hook.fromHub(POOL_A, enablePayload);
        assertTrue(hook.manager(address(mockShareToken), managerAddress));

        // Then disable
        bytes memory disablePayload = abi.encode(
            SC_1.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), false
        );
        vm.prank(envoy);
        vm.expectEmit();
        emit IShareTokenHook.UpdateHookManager(address(mockShareToken), managerAddress, false);
        hook.fromHub(POOL_A, disablePayload);
        assertFalse(hook.manager(address(mockShareToken), managerAddress));
    }

    function testFromHubShareTokenDoesNotExist() public {
        // Mock the share token to NOT exist (return address(0))
        vm.mockCall(
            address(mockSpoke),
            abi.encodeWithSelector(bytes4(keccak256("shareToken(uint64,bytes16)")), POOL_A.raw(), SC_1.raw()),
            abi.encode(address(0))
        );

        address managerAddress = makeAddr("manager");
        bytes memory payload = abi.encode(
            SC_1.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.expectRevert(IShareTokenHook.ShareTokenDoesNotExist.selector);
        vm.prank(envoy);
        hook.fromHub(POOL_A, payload);
    }

    function testFromHubNotEnvoy() public {
        address managerAddress = makeAddr("manager");
        bytes memory payload = abi.encode(
            SC_1.raw(), uint8(IShareTokenHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.expectRevert(IShareTokenHook.NotEnvoy.selector);
        vm.prank(user1); // Not the envoy
        hook.fromHub(POOL_A, payload);
    }
}

contract ShareTokenHookTestFuzz is ShareTokenHookTestBase {
    function testFuzzFreezeBit(uint128 hookData) public {
        mockShareToken.setHookData(user1, bytes16(hookData));

        bool expectedFrozen = BitmapLib.getBit(hookData, 0);
        assertEq(hook.isFrozen(address(mockShareToken), user1), expectedFrozen);
    }

    function testFuzzMembershipTimestamp(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));

        _updateMemberValidUntil(user1, validUntil);

        (bool isValid, uint64 storedValidUntil) = hook.isMember(address(mockShareToken), user1);
        assertTrue(isValid);
        assertEq(storedValidUntil, validUntil);
    }
}

contract ShareTokenHookTestEscrowResolution is ShareTokenHookTestBase {
    MockEscrow otherEscrow;
    address otherEscrowAddr;

    function setUp() public override {
        super.setUp();

        otherEscrow = new MockEscrow(PoolId.wrap(2));
        otherEscrowAddr = address(otherEscrow);
        mockEscrowProvider.setEscrow(PoolId.wrap(2), otherEscrowAddr);
    }

    function testRecognizesFactoryEscrow() public view {
        assertTrue(hook.isEscrow(escrow), "escrow registered in escrowProvider must be recognized");
        assertTrue(hook.isEscrow(otherEscrowAddr), "every registered escrow must be recognized, not just one");
    }

    function testRejectsNonFactoryEscrow(address random) public view {
        vm.assume(random != address(escrow) && random != otherEscrowAddr);

        assertFalse(hook.isEscrow(random), "escrow not registered in escrowProvider must be rejected");
    }

    function testUpdateMemberForeignEscrow() public {
        assertTrue(hook.isEscrow(otherEscrowAddr));

        _updateMemberValidUntil(otherEscrowAddr, FUTURE_TIMESTAMP);

        (bool isValid,) = hook.isMember(address(mockShareToken), otherEscrowAddr);
        assertTrue(isValid, "a token admits an escrow of another pool");
    }

    function testRejectsSelfDeclaredEscrow() public {
        MockEscrow impostor = new MockEscrow(TEST_POOL_ID);
        assertFalse(hook.isEscrow(address(impostor)), "self-declared poolId must not grant escrow status");
    }
}

/// @dev A vault holds shares mid-revocation, so the vaults of a token's own share class cannot be frozen
///      on it, and a freeze bit set before the vault was linked is ignored. The exemption is scoped to the
///      token: any pool can link a contract of its own as a vault.
contract ShareTokenHookTestShareClassVault is ShareTokenHookTestBase {
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16("scA"));
    ShareClassId constant SC_B = ShareClassId.wrap(bytes16("scB"));

    MockShareToken tokenB;
    address vaultA = makeAddr("vaultA");
    address vaultB = makeAddr("vaultB");
    address unlinkedVaultA = makeAddr("unlinkedVaultA");

    function setUp() public override {
        super.setUp();
        tokenB = new MockShareToken();
        mockSpoke.setShareToken(TEST_POOL_ID, SC_A, address(mockShareToken));
        mockSpoke.setShareToken(POOL_B, SC_B, address(tokenB));
        mockSpoke.setVault(vaultA, TEST_POOL_ID, SC_A, true);
        mockSpoke.setVault(vaultB, POOL_B, SC_B, true);
        mockSpoke.setVault(unlinkedVaultA, TEST_POOL_ID, SC_A, false);
    }

    function _setFreezeBit(MockShareToken token, address user) internal {
        token.setHookData(user, bytes16(uint128(1)));
    }

    function _checkAsToken(address token, address from, address to) internal returns (bool) {
        HookData memory hookData = HookData(mockShareToken.hookDataOf(from), bytes16(0));
        vm.prank(token);
        return hook.checkERC20Transfer(from, to, 1, hookData);
    }

    function testRecognizesOwnShareClassVault() public view {
        assertTrue(hook.isShareClassVault(address(mockShareToken), vaultA));
        assertTrue(hook.isShareClassVault(address(tokenB), vaultB));
        assertFalse(hook.isShareClassVault(address(mockShareToken), vaultB), "another pool's vault");
        assertFalse(hook.isShareClassVault(address(tokenB), vaultA), "another pool's vault");
        assertFalse(hook.isShareClassVault(address(mockShareToken), unlinkedVaultA), "unlinked");
        assertFalse(hook.isShareClassVault(address(mockShareToken), user1), "not a vault");
    }

    function testFreezeOwnShareClassVaultRefused() public {
        vm.expectRevert(IShareTokenHook.VaultCannotBeFrozen.selector);
        vm.prank(deployer);
        hook.freeze(address(mockShareToken), vaultA);
    }

    function testFreezeOtherPoolVaultAllowed() public {
        _freezeUser(vaultB);
        assertTrue(hook.isFrozen(address(mockShareToken), vaultB));
        assertFalse(_checkAsToken(address(mockShareToken), vaultB, user1), "pool B's vault is frozen on token A");
    }

    function testFreezeUnlinkedVaultAllowed() public {
        _freezeUser(unlinkedVaultA);
        assertFalse(_checkAsToken(address(mockShareToken), unlinkedVaultA, user1), "an unlinked vault is frozen");
    }

    /// @dev A vault's address is predictable, so a freeze bit can be set before it is linked.
    function testPreexistingFreezeBitIgnoredOnOwnShareClassVault() public {
        _setFreezeBit(mockShareToken, vaultA);
        _setFreezeBit(tokenB, vaultA);

        assertTrue(_checkAsToken(address(mockShareToken), vaultA, spoke), "own vault's freeze bit binds");
        assertFalse(
            _checkAsToken(address(tokenB), vaultA, spoke), "the exemption leaks to a token the vault does not serve"
        );
    }

    function testRoleCheckIgnoresOwnShareClassVaultFreezeBit() public {
        _setFreezeBit(mockShareToken, vaultA);
        _setFreezeBit(mockShareToken, vaultB);

        assertTrue(hook.checkRole(address(mockShareToken), RoleCheck(Role.Payout, user1, vaultA, 0, 0, Effect.Neutral)));
        assertFalse(
            hook.checkRole(address(mockShareToken), RoleCheck(Role.Payout, user1, vaultB, 0, 0, Effect.Neutral)),
            "pool B's vault is frozen on token A"
        );
    }
}
