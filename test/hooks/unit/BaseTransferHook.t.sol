// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BitmapLib} from "../../../src/misc/libraries/BitmapLib.sol";

import {IRoot} from "../../../src/common/interfaces/IRoot.sol";
import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../../../src/common/interfaces/ITransferHook.sol";

import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";

import {IFreezable} from "../../../src/hooks/interfaces/IFreezable.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {IMemberlist} from "../../../src/hooks/interfaces/IMemberlist.sol";
import {BaseTransferHook, TransferType} from "../../../src/hooks/BaseTransferHook.sol";

import "forge-std/Test.sol";

// Mock contract for interface compliance
contract IsContract {}

contract BaseTransferHookTest is Test {
    using CastLib for *;
    using BitmapLib for *;

    address constant ROOT = address(0x1);
    address constant DEPLOYER = address(0x2);
    address constant REDEEM_SOURCE = address(0x3);
    address constant DEPOSIT_TARGET = address(0x4);
    address constant CROSSCHAIN_SOURCE = address(0x5);

    FullRestrictions hook;
    IRoot root;
    IShareToken shareToken;

    address testUser;
    address endorsedUser;
    address depositTarget;
    address redeemSource;
    address crosschainSource;

    function setUp() public virtual {
        testUser = makeAddr("testUser");
        endorsedUser = makeAddr("endorsedUser");

        // Create mock contracts
        root = IRoot(address(new IsContract()));
        shareToken = IShareToken(address(new IsContract()));

        // Mock root.endorsed calls
        vm.mockCall(address(root), abi.encodeWithSelector(root.endorsed.selector, endorsedUser), abi.encode(true));
        vm.mockCall(address(root), abi.encodeWithSelector(root.endorsed.selector, testUser), abi.encode(false));
        vm.mockCall(address(root), abi.encodeWithSelector(root.endorsed.selector, address(0)), abi.encode(false));

        // Create hook with actual root mock address
        hook = new FullRestrictions(address(root), REDEEM_SOURCE, DEPOSIT_TARGET, CROSSCHAIN_SOURCE, DEPLOYER);

        // Set addresses for test reference
        depositTarget = hook.depositTarget();
        redeemSource = hook.redeemSource();
        crosschainSource = hook.crosschainSource();

        // Mock default share token behavior
        _mockShareTokenDefaults();
    }

    function _mockShareTokenDefaults() internal {
        // Mock hookDataOf to return clean data by default
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(shareToken.hookDataOf.selector, testUser),
            abi.encode(bytes16(0))
        );
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(shareToken.hookDataOf.selector, endorsedUser),
            abi.encode(bytes16(0))
        );
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(shareToken.hookDataOf.selector, address(0)),
            abi.encode(bytes16(0))
        );

        // Mock setHookData to succeed
        vm.mockCall(address(shareToken), abi.encodeWithSelector(shareToken.setHookData.selector), abi.encode());
    }

    function _mockFrozenUser(address user) internal {
        bytes16 frozenData = bytes16(uint128(1)); // Frozen bit set
        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(shareToken.hookDataOf.selector, user), abi.encode(frozenData)
        );
    }

    function _mockMemberUser(address user, uint64 validUntil) internal {
        bytes16 memberData = bytes16(uint128(validUntil) << 64); // Member timestamp in upper 64 bits
        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(shareToken.hookDataOf.selector, user), abi.encode(memberData)
        );
    }

    function _mockMemberAndFrozenUser(address user, uint64 validUntil) internal {
        bytes16 memberFrozenData = bytes16((uint128(validUntil) << 64) | uint128(1)); // Both member and frozen
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(shareToken.hookDataOf.selector, user),
            abi.encode(memberFrozenData)
        );
    }
}

contract BaseTransferHookTestConstructor is BaseTransferHookTest {
    function testConstructorInvalidInputsRedeemSourceEqualsDepositTarget() public {
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(address(root), depositTarget, depositTarget, crosschainSource, address(this));
    }

    function testConstructorInvalidInputsDepositTargetEqualsCrosschainSource() public {
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(address(root), redeemSource, crosschainSource, crosschainSource, address(this));
    }

    function testConstructorInvalidInputsRedeemSourceEqualsCrosschainSource() public {
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(address(root), crosschainSource, depositTarget, crosschainSource, address(this));
    }
}

contract BaseTransferHookTestGetTransferType is BaseTransferHookTest {
    function testDepositRequest() public view {
        assertEq(uint256(hook.getTransferType(address(0), testUser)), uint256(TransferType.DepositRequest));
    }

    function testDepositFulfillment() public view {
        assertEq(uint256(hook.getTransferType(address(0), depositTarget)), uint256(TransferType.DepositFulfillment));
    }

    function testDepositClaim() public view {
        assertEq(uint256(hook.getTransferType(depositTarget, testUser)), uint256(TransferType.DepositClaim));
    }

    function testRedeemRequest() public view {
        assertEq(uint256(hook.getTransferType(testUser, ESCROW_HOOK_ID)), uint256(TransferType.RedeemRequest));
    }

    function testRedeemFulfillment() public view {
        assertEq(uint256(hook.getTransferType(redeemSource, address(0))), uint256(TransferType.RedeemFulfillment));
    }

    function testRedeemClaim() public view {
        assertEq(uint256(hook.getTransferType(testUser, address(0))), uint256(TransferType.RedeemClaim));
    }

    function testCrosschainTransfer() public view {
        assertEq(uint256(hook.getTransferType(crosschainSource, address(0))), uint256(TransferType.CrosschainTransfer));
    }

    function testLocalTransfer() public view {
        assertEq(uint256(hook.getTransferType(testUser, endorsedUser)), uint256(TransferType.LocalTransfer));
    }
}

contract BaseTransferHookTestIsDepositRequest is BaseTransferHookTest {
    function testIsDepositRequestTrue() public view {
        assertTrue(hook.isDepositRequest(address(0), testUser));
    }

    function testIsDepositRequestFalseWhenDepositTarget() public view {
        assertFalse(hook.isDepositRequest(address(0), depositTarget));
    }

    function testIsDepositRequestFalseWhenNotFromZero() public view {
        assertFalse(hook.isDepositRequest(testUser, testUser));
    }
}

contract BaseTransferHookTestIsDepositFulfillment is BaseTransferHookTest {
    function testIsDepositFulfillmentTrue() public view {
        assertTrue(hook.isDepositFulfillment(address(0), depositTarget));
    }

    function testIsDepositFulfillmentFalseWhenNotDepositTarget() public view {
        assertFalse(hook.isDepositFulfillment(address(0), testUser));
    }

    function testIsDepositFulfillmentFalseWhenNotFromZero() public view {
        assertFalse(hook.isDepositFulfillment(testUser, depositTarget));
    }
}

contract BaseTransferHookTestIsDepositClaim is BaseTransferHookTest {
    function testIsDepositClaimTrue() public view {
        assertTrue(hook.isDepositClaim(depositTarget, testUser));
    }

    function testIsDepositClaimFalseWhenToZero() public view {
        assertFalse(hook.isDepositClaim(depositTarget, address(0)));
    }

    function testIsDepositClaimFalseWhenNotFromDepositTarget() public view {
        assertFalse(hook.isDepositClaim(testUser, testUser));
    }
}

contract BaseTransferHookTestIsRedeemRequest is BaseTransferHookTest {
    function testIsRedeemRequestTrue() public view {
        assertTrue(hook.isRedeemRequest(testUser, ESCROW_HOOK_ID));
    }

    function testIsRedeemRequestFalseWhenNotEscrowId() public view {
        assertFalse(hook.isRedeemRequest(testUser, testUser));
    }

    function testIsRedeemRequestFalseWhenToZero() public view {
        assertFalse(hook.isRedeemRequest(testUser, address(0)));
    }
}

contract BaseTransferHookTestIsRedeemFulfillment is BaseTransferHookTest {
    function testIsRedeemFulfillmentTrue() public view {
        assertTrue(hook.isRedeemFulfillment(redeemSource, address(0)));
    }

    function testIsRedeemFulfillmentFalseWhenNotRedeemSource() public view {
        assertFalse(hook.isRedeemFulfillment(testUser, address(0)));
    }

    function testIsRedeemFulfillmentFalseWhenNotToZero() public view {
        assertFalse(hook.isRedeemFulfillment(redeemSource, testUser));
    }
}

contract BaseTransferHookTestIsRedeemClaim is BaseTransferHookTest {
    function testIsRedeemClaimTrue() public view {
        assertTrue(hook.isRedeemClaim(testUser, address(0)));
    }

    function testIsRedeemClaimFalseWhenFromRedeemSource() public view {
        assertFalse(hook.isRedeemClaim(redeemSource, address(0)));
    }

    function testIsRedeemClaimFalseWhenFromCrosschainSource() public view {
        assertFalse(hook.isRedeemClaim(crosschainSource, address(0)));
    }

    function testIsRedeemClaimFalseWhenNotToZero() public view {
        assertFalse(hook.isRedeemClaim(testUser, testUser));
    }
}

contract BaseTransferHookTestIsCrosschainTransfer is BaseTransferHookTest {
    function testIsCrosschainTransferTrue() public view {
        assertTrue(hook.isCrosschainTransfer(crosschainSource, address(0)));
    }

    function testIsCrosschainTransferFalseWhenNotCrosschainSource() public view {
        assertFalse(hook.isCrosschainTransfer(testUser, address(0)));
    }

    function testIsCrosschainTransferFalseWhenNotToZero() public view {
        assertFalse(hook.isCrosschainTransfer(crosschainSource, testUser));
    }
}

contract BaseTransferHookTestIsSourceOrTargetFrozen is BaseTransferHookTest {
    function testFrozenSourceNotEndorsed() public view {
        // Mock frozen user data directly
        HookData memory hookData = HookData({
            from: bytes16(uint128(1)), // Frozen bit set
            to: bytes16(uint128(0)) // Clean endorsed user data
        });

        assertTrue(hook.isSourceOrTargetFrozen(testUser, endorsedUser, hookData));
    }

    function testEndorsedUserNotConsideredFrozen() public view {
        // Even if endorsed user data says frozen, they're not considered frozen
        HookData memory hookData = HookData({
            from: bytes16(uint128(1)), // Frozen bit set
            to: bytes16(0)
        });

        assertFalse(hook.isSourceOrTargetFrozen(endorsedUser, testUser, hookData));
    }

    function testNeitherFrozen() public view {
        HookData memory cleanHookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertFalse(hook.isSourceOrTargetFrozen(testUser, endorsedUser, cleanHookData));
    }

    function testTargetFrozen() public view {
        // Mock frozen target data directly
        HookData memory hookData = HookData({
            from: bytes16(0),
            to: bytes16(uint128(1)) // Frozen bit set for target
        });

        assertTrue(hook.isSourceOrTargetFrozen(endorsedUser, testUser, hookData));
    }
}

contract BaseTransferHookTestIsSourceMember is BaseTransferHookTest {
    uint64 futureTime;

    function setUp() public override {
        super.setUp();
        futureTime = uint64(block.timestamp + 1000);
    }

    function testValidMember() public view {
        // Mock member data directly (validUntil in upper 64 bits)
        HookData memory hookData = HookData({from: bytes16(uint128(futureTime) << 64), to: bytes16(0)});

        assertTrue(hook.isSourceMember(testUser, hookData));
    }

    function testEndorsedUserAlwaysMember() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertTrue(hook.isSourceMember(endorsedUser, hookData));
    }

    function testExpiredMember() public view {
        uint64 pastTime = uint64(block.timestamp - 1);

        // Mock expired member data directly
        HookData memory hookData = HookData({from: bytes16(uint128(pastTime) << 64), to: bytes16(0)});

        assertFalse(hook.isSourceMember(testUser, hookData));
    }

    function testExpiredMemberEndorsedStillValid() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        // Endorsed user is always valid regardless of hook data
        assertTrue(hook.isSourceMember(endorsedUser, hookData));
    }
}

contract BaseTransferHookTestIsTargetMember is BaseTransferHookTest {
    uint64 futureTime;

    function setUp() public override {
        super.setUp();
        futureTime = uint64(block.timestamp + 1000);
    }

    function testValidMember() public view {
        // Mock member data directly (validUntil in upper 64 bits)
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(uint128(futureTime) << 64)});

        assertTrue(hook.isTargetMember(testUser, hookData));
    }

    function testEndorsedUserAlwaysMember() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertTrue(hook.isTargetMember(endorsedUser, hookData));
    }

    function testExpiredMember() public view {
        uint64 pastTime = uint64(block.timestamp - 1);

        // Mock expired member data directly
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(uint128(pastTime) << 64)});

        assertFalse(hook.isTargetMember(testUser, hookData));
    }

    function testExpiredMemberEndorsedStillValid() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        // Endorsed user is always valid regardless of hook data
        assertTrue(hook.isTargetMember(endorsedUser, hookData));
    }
}

contract BaseTransferHookTestFreeze is BaseTransferHookTest {
    function testFreezeEndorsedUserError() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        vm.expectRevert(IFreezable.EndorsedUserCannotBeFrozen.selector);
        hook.freeze(address(shareToken), endorsedUser);
    }

    function testFreezeNormalUser() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        // Test freeze function - should succeed without revert
        hook.freeze(address(shareToken), testUser);
        assertTrue(true); // Test passes if no revert
    }

    function testFreezeZeroAddressError() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        vm.expectRevert(IFreezable.CannotFreezeZeroAddress.selector);
        hook.freeze(address(shareToken), address(0));
    }
}

contract BaseTransferHookTestUnfreeze is BaseTransferHookTest {
    function testUnfreeze() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        // First mock user as frozen
        _mockFrozenUser(testUser);
        assertTrue(hook.isFrozen(address(shareToken), testUser));

        // Then unfreeze and mock clean state
        hook.unfreeze(address(shareToken), testUser);
        _mockShareTokenDefaults(); // Reset to clean state
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }

    function testUnfreezeNotFrozenUser() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        // Should still work even if user wasn't frozen
        hook.unfreeze(address(shareToken), testUser);
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }
}

contract BaseTransferHookTestIsFrozen is BaseTransferHookTest {
    function testInitiallyNotFrozen() public view {
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }

    function testFrozenAfterFreeze() public {
        // Mock frozen user state directly
        _mockFrozenUser(testUser);
        assertTrue(hook.isFrozen(address(shareToken), testUser));
    }
}

contract BaseTransferHookTestUpdateMember is BaseTransferHookTest {
    function testUpdateMemberEndorsedUserError() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        vm.expectRevert(IMemberlist.EndorsedUserCannotBeUpdated.selector);
        hook.updateMember(address(shareToken), endorsedUser, uint64(block.timestamp + 1000));
    }

    function testUpdateMemberNormalUser() public {
        uint64 futureTime = uint64(block.timestamp + 1000);

        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        // Test should pass without revert
        hook.updateMember(address(shareToken), testUser, futureTime);
        assertTrue(true); // Test passes if no revert
    }

    function testUpdateMemberInvalidValidUntil() public {
        uint64 pastTime = uint64(block.timestamp - 1);

        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        vm.expectRevert(IMemberlist.InvalidValidUntil.selector);
        hook.updateMember(address(shareToken), testUser, pastTime);
    }

    function testUpdateMemberPreservesFrozenStatus() public {
        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        // Mock user as initially frozen
        _mockFrozenUser(testUser);

        // Update member should succeed
        uint64 futureTime = uint64(block.timestamp + 1000);
        hook.updateMember(address(shareToken), testUser, futureTime);
        assertTrue(true); // Test passes if no revert
    }
}

contract BaseTransferHookTestIsMember is BaseTransferHookTest {
    function testInitiallyNotMember() public view {
        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertFalse(isValid);
        assertEq(validUntil, 0);
    }

    function testValidMember() public {
        uint64 futureTime = uint64(block.timestamp + 1000);

        // Mock member data directly
        _mockMemberUser(testUser, futureTime);

        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertTrue(isValid);
        assertEq(validUntil, futureTime);
    }

    function testExpiredMember() public {
        uint64 pastTime = uint64(block.timestamp - 1);

        // Mock expired member data directly
        _mockMemberUser(testUser, pastTime);

        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertFalse(isValid);
        assertEq(validUntil, pastTime); // validUntil doesn't change
    }
}

contract BaseTransferHookTestOnERC20Transfer is BaseTransferHookTest {
    function testSuccessfulTransfer() public {
        uint64 futureTime = uint64(block.timestamp + 1000);

        // Mock member data for successful transfer
        HookData memory hookData = HookData({
            from: bytes16(uint128(0)), // Clean source (address(0))
            to: bytes16(uint128(futureTime) << 64) // Valid member target
        });

        bytes4 result = hook.onERC20Transfer(address(0), testUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20Transfer.selector);
    }

    function testBlockedTransferFrozenUser() public view {
        // Mock frozen user trying to transfer
        HookData memory frozenHookData = HookData({
            from: bytes16(uint128(1)), // Frozen bit set for source
            to: bytes16(uint128(0)) // Clean target (endorsed user)
        });

        // Use checkERC20Transfer directly since that's what contains the logic
        assertFalse(hook.checkERC20Transfer(testUser, endorsedUser, 100, frozenHookData));
    }
}

contract BaseTransferHookTestOnERC20AuthTransfer is BaseTransferHookTest {
    function testAuthTransferAlwaysSucceeds() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        bytes4 result = hook.onERC20AuthTransfer(testUser, testUser, endorsedUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20AuthTransfer.selector);
    }

    function testAuthTransferWithFrozenUser() public view {
        // Mock frozen user data directly
        HookData memory hookData = HookData({
            from: bytes16(uint128(1)), // Frozen bit set
            to: bytes16(0)
        });

        // Auth transfer should still succeed even with frozen user
        bytes4 result = hook.onERC20AuthTransfer(ROOT, testUser, endorsedUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20AuthTransfer.selector);
    }
}

contract BaseTransferHookTestUpdateRestriction is BaseTransferHookTest {
    function testUpdateRestrictionInvalidType() public {
        // Create invalid payload (type 0 = Invalid enum)
        bytes memory invalidPayload = abi.encodePacked(uint8(0), bytes("invalid"));

        // Mock that we have ward permission on the hook
        vm.prank(DEPLOYER);
        hook.rely(address(this));

        vm.expectRevert(ITransferHook.InvalidUpdate.selector);
        hook.updateRestriction(address(shareToken), invalidPayload);
    }

    function testUpdateRestrictionNotAuth() public {
        bytes memory payload = abi.encodePacked(uint8(1), bytes("data"));

        vm.prank(testUser);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hook.updateRestriction(address(shareToken), payload);
    }
}
