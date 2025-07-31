// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BitmapLib} from "../../../src/misc/libraries/BitmapLib.sol";

import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../../../src/common/interfaces/ITransferHook.sol";

import "../../spoke/integration/BaseTest.sol";

import {IFreezable} from "../../../src/hooks/interfaces/IFreezable.sol";
import {FullRestrictions} from "../../../src/hooks/FullRestrictions.sol";
import {IMemberlist} from "../../../src/hooks/interfaces/IMemberlist.sol";
import {BaseTransferHook, TransferType} from "../../../src/hooks/BaseTransferHook.sol";

contract BaseTransferHookTest is BaseTest {
    using CastLib for *;
    using BitmapLib for *;

    FullRestrictions hook;
    address testUser;
    address endorsedUser;
    address depositTarget;
    address redeemSource;
    address crosschainSource;

    function setUp() public virtual override {
        super.setUp();

        hook = FullRestrictions(fullRestrictionsHook);
        testUser = makeAddr("testUser");
        endorsedUser = makeAddr("endorsedUser");

        // Get the addresses from the hook
        depositTarget = hook.depositTarget();
        redeemSource = hook.redeemSource();
        crosschainSource = hook.crosschainSource();

        // Set up endorsed user - use guardian for root authorization
        vm.prank(address(guardian));
        root.endorse(endorsedUser);
    }
}

contract BaseTransferHookTestConstructor is BaseTransferHookTest {
    function testConstructorInvalidInputs() public {
        address root_ = address(root);
        address deployer = address(this);

        // Test redeemSource == depositTarget
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(root_, depositTarget, depositTarget, crosschainSource, deployer);

        // Test depositTarget == crosschainSource
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(root_, redeemSource, crosschainSource, crosschainSource, deployer);

        // Test redeemSource == crosschainSource
        vm.expectRevert(BaseTransferHook.InvalidInputs.selector);
        new FullRestrictions(root_, crosschainSource, depositTarget, crosschainSource, deployer);
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
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testFrozenSourceNotEndorsed() public {
        // Freeze testUser
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);

        HookData memory hookData = HookData({
            from: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser))),
            to: bytes16(uint128(IShareToken(shareToken).hookDataOf(endorsedUser)))
        });

        assertTrue(hook.isSourceOrTargetFrozen(testUser, endorsedUser, hookData));
    }

    function testEndorsedUserNotConsideredFrozen() public {
        // Even if endorsed user data says frozen, they're not considered frozen
        HookData memory hookData = HookData({
            from: bytes16(uint128(1)), // Frozen bit set
            to: bytes16(0)
        });

        assertFalse(hook.isSourceOrTargetFrozen(endorsedUser, testUser, hookData));
    }

    function testNeitherFrozen() public {
        HookData memory cleanHookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertFalse(hook.isSourceOrTargetFrozen(testUser, endorsedUser, cleanHookData));
    }

    function testTargetFrozen() public {
        // Freeze testUser
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);

        HookData memory hookData =
            HookData({from: bytes16(0), to: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser)))});

        assertTrue(hook.isSourceOrTargetFrozen(endorsedUser, testUser, hookData));
    }
}

contract BaseTransferHookTestIsSourceMember is BaseTransferHookTest {
    IShareToken shareToken;
    uint64 futureTime;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
        futureTime = uint64(block.timestamp + 1000);
    }

    function testValidMember() public {
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        HookData memory hookData =
            HookData({from: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser))), to: bytes16(0)});

        assertTrue(hook.isSourceMember(testUser, hookData));
    }

    function testEndorsedUserAlwaysMember() public {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertTrue(hook.isSourceMember(endorsedUser, hookData));
    }

    function testExpiredMember() public {
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        HookData memory hookData =
            HookData({from: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser))), to: bytes16(0)});

        // Fast forward past expiry
        vm.warp(block.timestamp + 2000);
        assertFalse(hook.isSourceMember(testUser, hookData));
    }

    function testExpiredMemberEndorsedStillValid() public {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        // Even after time warp, endorsed user is still valid
        vm.warp(block.timestamp + 2000);
        assertTrue(hook.isSourceMember(endorsedUser, hookData));
    }
}

contract BaseTransferHookTestIsTargetMember is BaseTransferHookTest {
    IShareToken shareToken;
    uint64 futureTime;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
        futureTime = uint64(block.timestamp + 1000);
    }

    function testValidMember() public {
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        HookData memory hookData =
            HookData({from: bytes16(0), to: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser)))});

        assertTrue(hook.isTargetMember(testUser, hookData));
    }

    function testEndorsedUserAlwaysMember() public {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});
        assertTrue(hook.isTargetMember(endorsedUser, hookData));
    }

    function testExpiredMember() public {
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        HookData memory hookData =
            HookData({from: bytes16(0), to: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser)))});

        // Fast forward past expiry
        vm.warp(block.timestamp + 2000);
        assertFalse(hook.isTargetMember(testUser, hookData));
    }

    function testExpiredMemberEndorsedStillValid() public {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        // Even after time warp, endorsed user is still valid
        vm.warp(block.timestamp + 2000);
        assertTrue(hook.isTargetMember(endorsedUser, hookData));
    }
}

contract BaseTransferHookTestFreeze is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testFreezeEndorsedUserError() public {
        vm.prank(address(root));
        vm.expectRevert(IFreezable.EndorsedUserCannotBeFrozen.selector);
        hook.freeze(address(shareToken), endorsedUser);
    }

    function testFreezeNormalUser() public {
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);
        assertTrue(hook.isFrozen(address(shareToken), testUser));
    }

    function testFreezeZeroAddressError() public {
        vm.prank(address(root));
        vm.expectRevert(IFreezable.CannotFreezeZeroAddress.selector);
        hook.freeze(address(shareToken), address(0));
    }
}

contract BaseTransferHookTestUnfreeze is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testUnfreeze() public {
        // First freeze the user
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);
        assertTrue(hook.isFrozen(address(shareToken), testUser));

        // Then unfreeze
        vm.prank(address(root));
        hook.unfreeze(address(shareToken), testUser);
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }

    function testUnfreezeNotFrozenUser() public {
        // Should still work even if user wasn't frozen
        vm.prank(address(root));
        hook.unfreeze(address(shareToken), testUser);
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }
}

contract BaseTransferHookTestIsFrozen is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testInitiallyNotFrozen() public view {
        assertFalse(hook.isFrozen(address(shareToken), testUser));
    }

    function testFrozenAfterFreeze() public {
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);
        assertTrue(hook.isFrozen(address(shareToken), testUser));
    }
}

contract BaseTransferHookTestUpdateMember is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testUpdateMemberEndorsedUserError() public {
        vm.prank(address(root));
        vm.expectRevert(IMemberlist.EndorsedUserCannotBeUpdated.selector);
        hook.updateMember(address(shareToken), endorsedUser, uint64(block.timestamp + 1000));
    }

    function testUpdateMemberNormalUser() public {
        uint64 futureTime = uint64(block.timestamp + 1000);

        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertTrue(isValid);
        assertEq(validUntil, futureTime);
    }

    function testUpdateMemberInvalidValidUntil() public {
        uint64 pastTime = uint64(block.timestamp - 1);

        vm.prank(address(root));
        vm.expectRevert(IMemberlist.InvalidValidUntil.selector);
        hook.updateMember(address(shareToken), testUser, pastTime);
    }

    function testUpdateMemberPreservesFrozenStatus() public {
        // First freeze the user
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);

        // Update member
        uint64 futureTime = uint64(block.timestamp + 1000);
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        // Check user is still frozen
        assertTrue(hook.isFrozen(address(shareToken), testUser));
    }
}

contract BaseTransferHookTestIsMember is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testInitiallyNotMember() public view {
        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertFalse(isValid);
        assertEq(validUntil, 0);
    }

    function testValidMember() public {
        uint64 futureTime = uint64(block.timestamp + 1000);
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertTrue(isValid);
        assertEq(validUntil, futureTime);
    }

    function testExpiredMember() public {
        uint64 futureTime = uint64(block.timestamp + 1000);
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, futureTime);

        // Fast forward past expiry
        vm.warp(block.timestamp + 2000);

        (bool isValid, uint64 validUntil) = hook.isMember(address(shareToken), testUser);
        assertFalse(isValid);
        assertEq(validUntil, futureTime); // validUntil doesn't change
    }
}

contract BaseTransferHookTestOnERC20Transfer is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testSuccessfulTransfer() public {
        // Set up testUser as a member
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, uint64(block.timestamp + 1000));

        HookData memory hookData = HookData({
            from: bytes16(uint128(IShareToken(shareToken).hookDataOf(address(0)))),
            to: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser)))
        });

        bytes4 result = hook.onERC20Transfer(address(0), testUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20Transfer.selector);
    }

    function testBlockedTransferFrozenUser() public {
        // Set up testUser as a member
        vm.prank(address(root));
        hook.updateMember(address(shareToken), testUser, uint64(block.timestamp + 1000));

        // Freeze testUser
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);

        HookData memory frozenHookData = HookData({
            from: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser))),
            to: bytes16(uint128(IShareToken(shareToken).hookDataOf(endorsedUser)))
        });

        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        hook.onERC20Transfer(testUser, endorsedUser, 100, frozenHookData);
    }
}

contract BaseTransferHookTestOnERC20AuthTransfer is BaseTransferHookTest {
    function testAuthTransferAlwaysSucceeds() public view {
        HookData memory hookData = HookData({from: bytes16(0), to: bytes16(0)});

        bytes4 result = hook.onERC20AuthTransfer(testUser, testUser, endorsedUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20AuthTransfer.selector);
    }

    function testAuthTransferWithFrozenUser() public {
        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        IShareToken shareToken = IShareToken(AsyncVault(vault_).share());

        // Freeze testUser
        vm.prank(address(root));
        hook.freeze(address(shareToken), testUser);

        HookData memory hookData =
            HookData({from: bytes16(uint128(IShareToken(shareToken).hookDataOf(testUser))), to: bytes16(0)});

        // Auth transfer should still succeed even with frozen user
        bytes4 result = hook.onERC20AuthTransfer(address(root), testUser, endorsedUser, 100, hookData);
        assertEq(result, ITransferHook.onERC20AuthTransfer.selector);
    }
}

contract BaseTransferHookTestUpdateRestriction is BaseTransferHookTest {
    IShareToken shareToken;

    function setUp() public override {
        super.setUp();

        (, address vault_,) = deployVault(VaultKind.Async, 6, address(hook), bytes16(bytes("1")), address(erc20), 0, 0);
        shareToken = IShareToken(AsyncVault(vault_).share());
    }

    function testUpdateRestrictionInvalidType() public {
        // Create invalid payload (type 0 = Invalid enum)
        bytes memory invalidPayload = abi.encodePacked(uint8(0), bytes("invalid"));

        vm.prank(address(root));
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
