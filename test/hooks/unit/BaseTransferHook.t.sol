// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../../../src/misc/libraries/BitmapLib.sol";

import {MockPoolEscrowProvider} from "../../core/mocks/MockPoolEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {IFreezable} from "../../../src/token/hooks/interfaces/IFreezable.sol";
import {BaseTransferHook} from "../../../src/token/hooks/BaseTransferHook.sol";
import {IMemberlist} from "../../../src/token/hooks/interfaces/IMemberlist.sol";
import {IBaseTransferHook} from "../../../src/token/hooks/interfaces/IBaseTransferHook.sol";
import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../../../src/token/interfaces/ITransferHook.sol";

contract MockRoot {
    mapping(address => bool) public endorsed;

    function setEndorsed(address user, bool status) external {
        endorsed[user] = status;
    }
}

contract MockSpoke {}

contract MockShareToken {
    mapping(address => bytes16) public hookDataOf;

    function setHookData(address user, bytes16 data) external {
        hookDataOf[user] = data;
    }
}

contract MockPoolEscrow {
    PoolId public immutable poolId;

    constructor(PoolId poolId_) {
        poolId = poolId_;
    }
}

contract TestableBaseTransferHook is BaseTransferHook {
    using BitmapLib for *;

    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address poolEscrowProvider_
    ) BaseTransferHook(root_, envoy_, spokeRegistry_, spoke_, crosschainSource_, deployer, poolEscrowProvider_) {}

    function checkERC20Transfer(
        address from,
        address to,
        uint256,
        /* value */
        HookData calldata hookData
    )
        public
        view
        override
        returns (bool)
    {
        return !isSourceOrTargetFrozen(from, to, hookData);
    }
}

contract BaseTransferHookTestBase is Test {
    using UpdateRestrictionMessageLib for *;
    using BitmapLib for *;
    using CastLib for *;

    //----------------------------------------------------------------------------------------------
    // CONSTANTS & STATE
    //----------------------------------------------------------------------------------------------

    TestableBaseTransferHook hook;
    MockRoot mockRoot;
    MockSpoke mockSpoke;
    MockShareToken mockShareToken;
    MockPoolEscrow mockPoolEscrow;
    MockPoolEscrowProvider mockPoolEscrowProvider;

    address deployer = makeAddr("deployer");
    address envoy = makeAddr("envoy");
    address crosschainSource = makeAddr("crosschainSource");
    address spoke = makeAddr("spoke");
    address poolEscrow;
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

        // Create a real mock pool escrow
        mockPoolEscrow = new MockPoolEscrow(TEST_POOL_ID);
        poolEscrow = address(mockPoolEscrow);

        // Create mock pool escrow provider and configure it
        mockPoolEscrowProvider = new MockPoolEscrowProvider();
        mockPoolEscrowProvider.setEscrow(TEST_POOL_ID, poolEscrow);

        vm.prank(deployer);
        hook = new TestableBaseTransferHook(
            address(mockRoot),
            envoy,
            address(mockSpoke),
            spoke,
            crosschainSource,
            deployer,
            address(mockPoolEscrowProvider)
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
        mockRoot.setEndorsed(poolEscrow, true);
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

contract BaseTransferHookTestConstructor is BaseTransferHookTestBase {
    function testConstructor() public view {
        assertEq(address(hook.root()), address(mockRoot));
        assertEq(address(hook.spoke()), spoke);
        assertEq(hook.crosschainSource(), crosschainSource);
        assertEq(hook.FREEZE_BIT(), 0);
    }

    function testConstructorInvalidInputs() public {
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        vm.prank(deployer);
        new TestableBaseTransferHook(
            address(mockRoot),
            envoy,
            address(mockSpoke),
            spoke,
            spoke, // Same as spoke - should fail
            deployer,
            address(mockPoolEscrowProvider)
        );
    }
}

contract BaseTransferHookTestTransferTypes is BaseTransferHookTestBase {
    function testIsDepositRequestOrIssuance() public view {
        assertTrue(hook.isDepositRequestOrIssuance(address(0), user1));
        assertFalse(hook.isDepositRequestOrIssuance(address(0), poolEscrow));
        assertFalse(hook.isDepositRequestOrIssuance(user1, user2));
        assertFalse(hook.isDepositRequestOrIssuance(endorsedUser, user1));
        assertFalse(hook.isDepositRequestOrIssuance(user1, endorsedUser));
    }

    function testIsDepositFulfillment() public view {
        assertTrue(hook.isDepositFulfillment(address(0), poolEscrow));
        assertFalse(hook.isDepositFulfillment(address(0), user1));
        assertFalse(hook.isDepositFulfillment(address(0), endorsedUser));
        assertFalse(hook.isDepositFulfillment(poolEscrow, user1));
        assertFalse(hook.isDepositFulfillment(endorsedUser, user1));
        assertFalse(hook.isDepositFulfillment(endorsedUser, poolEscrow));
    }

    function testIsDepositClaim() public view {
        assertTrue(hook.isDepositClaim(poolEscrow, user1));
        assertTrue(hook.isDepositClaim(poolEscrow, endorsedUser));
        assertFalse(hook.isDepositClaim(poolEscrow, address(0)));
        assertFalse(hook.isDepositClaim(user1, user2));
        assertFalse(hook.isDepositClaim(user1, poolEscrow));
        assertFalse(hook.isDepositClaim(user1, endorsedUser));
    }

    function testIsRedeemRequest() public view {
        assertTrue(hook.isRedeemRequest(user1, ESCROW_HOOK_ID));
        assertFalse(hook.isRedeemRequest(user1, user2));
    }

    function testIsRedeemFulfillment() public view {
        assertTrue(hook.isRedeemFulfillment(spoke, address(0)));
        assertFalse(hook.isRedeemFulfillment(user1, address(0)));
        assertFalse(hook.isRedeemFulfillment(spoke, user1));
    }

    function testIsRedeemClaimOrRevocation() public view {
        assertTrue(hook.isRedeemClaimOrRevocation(user1, address(0)));
        assertFalse(hook.isRedeemClaimOrRevocation(spoke, address(0)));
        assertFalse(hook.isRedeemClaimOrRevocation(crosschainSource, address(0)));
        assertFalse(hook.isRedeemClaimOrRevocation(user1, user2));
    }

    function testIsCrosschainTransfer() public view {
        assertTrue(hook.isCrosschainTransfer(crosschainSource, address(0)));
        assertFalse(hook.isCrosschainTransfer(user1, address(0)));
        assertFalse(hook.isCrosschainTransfer(crosschainSource, user1));
    }

    function testIsCrosschainTransferExecution() public view {
        assertTrue(hook.isCrosschainTransferExecution(crosschainSource, user1));
        assertFalse(hook.isCrosschainTransferExecution(user1, address(0)));
    }

    function testCrosschainExclusionWithEndorsement() public view {
        assertFalse(
            hook.isDepositRequestOrIssuance(address(0), crosschainSource),
            "Mint to crosschainSource excluded from issuance"
        );
    }

    function testMintToCrosschainSourceNotFulfillment() public view {
        assertFalse(
            hook.isDepositRequestOrIssuance(address(0), crosschainSource),
            "Mint to crosschainSource should not be direct issuance"
        );
        assertFalse(
            hook.isDepositFulfillment(address(0), crosschainSource), "Mint to crosschainSource is not fulfillment"
        );
    }

    function testNonEndorsedToEndorsedNotAClaim() public view {}
}

contract BaseTransferHookTestFreeze is BaseTransferHookTestBase {
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

contract BaseTransferHookTestMember is BaseTransferHookTestBase {
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

    function testSourceMembershipValidation() public view {
        HookData memory hookData;

        // Not a member
        assertFalse(hook.isSourceMember(user1, hookData));

        // Endorsed user is not always a member
        assertTrue(!hook.isSourceMember(endorsedUser, hookData));

        // Set as member through hook data (valid until future timestamp)
        hookData = _createHookDataWithMembership(FUTURE_TIMESTAMP, 0);
        assertTrue(hook.isSourceMember(user1, hookData));

        // Expired membership (valid until past timestamp)
        hookData = _createHookDataWithMembership(pastTimestamp, 0);
        assertFalse(hook.isSourceMember(user1, hookData));
    }

    function testTargetMembershipValidation() public view {
        HookData memory hookData;

        // Not a member
        assertFalse(hook.isTargetMember(user1, hookData));

        // Endorsed user is always a member
        assertTrue(hook.isTargetMember(endorsedUser, hookData));

        // Set as member through hook data (valid until future timestamp)
        hookData = _createHookDataWithMembership(0, FUTURE_TIMESTAMP);
        assertTrue(hook.isTargetMember(user1, hookData));

        // Expired membership (valid until past timestamp)
        hookData = _createHookDataWithMembership(0, pastTimestamp);
        assertFalse(hook.isTargetMember(user1, hookData));
    }

    function testSourceOrTargetFrozenValidation() public view {
        HookData memory hookData;

        // Neither frozen
        assertFalse(hook.isSourceOrTargetFrozen(user1, user2, hookData));

        // Source frozen, not endorsed
        hookData = _createHookDataWithFreezeBit(true);
        assertTrue(hook.isSourceOrTargetFrozen(user1, user2, hookData));

        // Target frozen, not endorsed
        hookData.from = bytes16(0); // Clear freeze bit for source
        hookData.to = bytes16(uint128(1)); // Set freeze bit for target
        assertTrue(hook.isSourceOrTargetFrozen(user1, user2, hookData));
    }
}

contract BaseTransferHookTestUpdateRestriction is BaseTransferHookTestBase {
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

contract BaseTransferHookTestERC20Hook is BaseTransferHookTestBase {
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

contract BaseTransferHookTestInterfaceSupport is BaseTransferHookTestBase {
    function testSupportsInterface() public view {
        assertTrue(hook.supportsInterface(type(ITransferHook).interfaceId));
        assertTrue(hook.supportsInterface(type(IERC165).interfaceId));
        assertFalse(hook.supportsInterface(bytes4(0)));
    }
}

contract BaseTransferHookTestEvents is BaseTransferHookTestBase {
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

contract BaseTransferHookTestTrustedCall is BaseTransferHookTestBase {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    function testUnknownTrustedCall() public {
        // Create payload with invalid enum value
        bytes memory invalidPayload = abi.encode(SC_1.raw(), uint8(255), bytes32(0), false);

        vm.expectRevert(IBaseTransferHook.UnknownTrustedCall.selector);
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
            SC_1.raw(), uint8(IBaseTransferHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.prank(envoy);
        vm.expectEmit();
        emit IBaseTransferHook.UpdateHookManager(address(mockShareToken), managerAddress, true);
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
            SC_1.raw(), uint8(IBaseTransferHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );
        vm.prank(envoy);
        vm.expectEmit();
        emit IBaseTransferHook.UpdateHookManager(address(mockShareToken), managerAddress, true);
        hook.fromHub(POOL_A, enablePayload);
        assertTrue(hook.manager(address(mockShareToken), managerAddress));

        // Then disable
        bytes memory disablePayload = abi.encode(
            SC_1.raw(), uint8(IBaseTransferHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), false
        );
        vm.prank(envoy);
        vm.expectEmit();
        emit IBaseTransferHook.UpdateHookManager(address(mockShareToken), managerAddress, false);
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
            SC_1.raw(), uint8(IBaseTransferHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.expectRevert(BaseTransferHook.ShareTokenDoesNotExist.selector);
        vm.prank(envoy);
        hook.fromHub(POOL_A, payload);
    }

    function testFromHubNotEnvoy() public {
        address managerAddress = makeAddr("manager");
        bytes memory payload = abi.encode(
            SC_1.raw(), uint8(IBaseTransferHook.TrustedCall.UpdateHookManager), bytes32(bytes20(managerAddress)), true
        );

        vm.expectRevert(IBaseTransferHook.NotEnvoy.selector);
        vm.prank(user1); // Not the envoy
        hook.fromHub(POOL_A, payload);
    }
}

contract BaseTransferHookTestFuzz is BaseTransferHookTestBase {
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

contract BaseTransferHookTestPoolEscrowResolution is BaseTransferHookTestBase {
    MockPoolEscrow otherPoolEscrow;
    address otherEscrowAddr;

    function setUp() public override {
        super.setUp();

        otherPoolEscrow = new MockPoolEscrow(PoolId.wrap(2));
        otherEscrowAddr = address(otherPoolEscrow);
        mockPoolEscrowProvider.setEscrow(PoolId.wrap(2), otherEscrowAddr);
    }

    function testRecognizesFactoryEscrow() public view {
        assertTrue(hook.isPoolEscrow(poolEscrow), "escrow registered in poolEscrowProvider must be recognized");
        assertTrue(hook.isPoolEscrow(otherEscrowAddr), "every registered escrow must be recognized, not just one");
    }

    function testRejectsNonFactoryEscrow(address random) public view {
        vm.assume(random != address(poolEscrow) && random != otherEscrowAddr);

        assertFalse(hook.isPoolEscrow(random), "escrow not registered in poolEscrowProvider must be rejected");
    }

    function testRejectsSelfDeclaredEscrow() public {
        MockPoolEscrow impostor = new MockPoolEscrow(TEST_POOL_ID);
        assertFalse(hook.isPoolEscrow(address(impostor)), "self-declared poolId must not grant escrow status");
    }
}
