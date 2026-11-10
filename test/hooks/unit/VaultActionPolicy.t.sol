// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockRoot, MockShareToken} from "./ShareTokenHook.t.sol";

import {MockEscrowProvider} from "../../core/mocks/MockEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";

import {VaultActionKind} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {MockVaultRegistry} from "../mocks/MockVaultRegistry.sol";
import {VaultAction, VaultActionCheck} from "../mocks/VaultActionCheck.sol";

import "forge-std/Test.sol";

import {ITransferHook} from "../../../src/token/interfaces/ITransferHook.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../../src/token/interfaces/IRoleHook.sol";

/// @notice Unit coverage for the vault actions as the restriction hooks answer them, through the role checks the vault
///         maps each to: the per-flavor policy matrix, the ordering between flavors, and the base `onRoles`
///         stateless enforcement. The real hooks are exercised here because the vault unit tests mock the share
///         token's hook.
contract VaultActionPolicyTest is Test {
    using VaultActionCheck for *;
    PoolId constant POOL = PoolId.wrap(1);
    PoolId constant OTHER_POOL = PoolId.wrap(2);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));

    MockRoot root = new MockRoot();
    MockShareToken share = new MockShareToken();
    MockEscrowProvider escrowProvider = new MockEscrowProvider();
    MockVaultRegistry registry = new MockVaultRegistry();

    address deployer = makeAddr("deployer");
    address controller = makeAddr("controller");
    address owner = makeAddr("owner");
    address receiver = makeAddr("receiver");
    address endorsed = makeAddr("endorsed");

    function _deploy(uint8 policy) internal returns (ShareTokenHook) {
        // Only root, spokeRegistry, deployer and escrowProvider matter here.
        return new ShareTokenHook(
            address(root),
            makeAddr("envoy"),
            address(registry),
            makeAddr("spoke"),
            makeAddr("crosschainSource"),
            deployer,
            address(escrowProvider),
            policy
        );
    }

    function _member(address user) internal {
        // hookData: validUntil in the high 64 bits.
        share.setHookData(user, bytes16(uint128(uint64(type(uint64).max)) << 64));
    }

    function _frozen(address user) internal {
        // Freeze bit (LSB) set, and a live membership so freezing is the sole cause of a block.
        share.setHookData(user, bytes16(uint128(uint64(type(uint64).max)) << 64 | uint128(1)));
    }

    function _action(VaultActionKind kind, address controller_, address owner_, address receiver_)
        internal
        pure
        returns (VaultAction memory)
    {
        return VaultAction(kind, controller_, owner_, receiver_, 0);
    }

    // --- FullRestrictions: members (or endorsed) may request and receive; redeem source strict ---

    function testFullRestrictions() public {
        ShareTokenHook hook = _deploy(HookPolicies.fullRestrictions());

        // DepositRequest: controller must be a member (or endorsed) and not frozen.
        assertFalse(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );
        _member(controller);
        assertTrue(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );
        root.setEndorsed(endorsed, true);
        assertTrue(hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, endorsed, owner, endorsed)));
        _frozen(controller);
        assertFalse(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );

        _member(receiver);

        // RedeemRequest: owner must be a strict member (endorsement does not substitute).
        assertFalse(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));
        _member(owner);
        assertTrue(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));

        // RedeemClaim: the payout receiver must be a member, the controller itself included.
        assertTrue(hook.checkAction(address(share), _action(VaultActionKind.RedeemClaim, owner, address(0), owner)));
        address stranger = makeAddr("stranger");
        assertFalse(hook.checkAction(address(share), _action(VaultActionKind.RedeemClaim, owner, address(0), stranger)));
    }

    /// @dev Redemption proceeds go to a member, the controller itself included: a holder whose membership lapsed
    ///      between the request and the claim is refused, under both flavors that gate the payout, until it is
    ///      renewed. The flavors that do not gate it still pay them, and a freeze refuses all.
    function testALapsedControllerIsNotPaidItsOwnProceeds() public {
        ShareTokenHook full = _deploy(HookPolicies.fullRestrictions());
        ShareTokenHook freely = _deploy(HookPolicies.freelyTransferable());
        ShareTokenHook redemption = _deploy(HookPolicies.redemptionRestrictions());
        ShareTokenHook freezeOnly = _deploy(HookPolicies.freezeOnly());
        VaultAction memory claim = _action(VaultActionKind.RedeemClaim, controller, address(0), controller);
        VaultAction memory instant = _action(VaultActionKind.InstantRedeem, controller, controller, controller);

        // Never a member, or lapsed: the same to the hook
        assertFalse(full.checkAction(address(share), claim), "FullRestrictions paid a lapsed controller");
        assertFalse(freely.checkAction(address(share), claim), "FreelyTransferable paid a lapsed controller");
        assertFalse(full.checkAction(address(share), instant));
        assertFalse(freely.checkAction(address(share), instant));
        assertTrue(freezeOnly.checkAction(address(share), claim));

        _member(controller);
        assertTrue(full.checkAction(address(share), claim), "a renewed member is paid");
        assertTrue(freely.checkAction(address(share), claim));
        assertTrue(full.checkAction(address(share), instant));
        assertTrue(freely.checkAction(address(share), instant));
        assertTrue(redemption.checkAction(address(share), claim));

        _frozen(controller);
        assertFalse(full.checkAction(address(share), claim));
        assertFalse(freely.checkAction(address(share), claim));
        assertFalse(redemption.checkAction(address(share), claim));
    }

    // --- RedemptionRestrictions: only redeem requests are membership-gated ---

    function testRedemptionRestrictions() public {
        ShareTokenHook hook = _deploy(HookPolicies.redemptionRestrictions());

        // A deposit request needs only a non-frozen party.
        assertTrue(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );

        // Redeem request needs a member source.
        assertFalse(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));
        _member(owner);
        assertTrue(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));

        // Freeze blocks everything.
        _frozen(controller);
        assertFalse(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );
    }

    // --- FreezeOnly: only the freeze bit gates ---

    function testFreezeOnly() public {
        ShareTokenHook hook = _deploy(HookPolicies.freezeOnly());

        assertTrue(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );
        assertTrue(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));
        _frozen(owner);
        assertFalse(hook.checkAction(address(share), _action(VaultActionKind.RedeemRequest, owner, owner, address(0))));
    }

    // --- FreelyTransferable: requests membership-gated; redeem payout strict member ---

    function testFreelyTransferable() public {
        ShareTokenHook hook = _deploy(HookPolicies.freelyTransferable());

        assertFalse(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );
        _member(controller);
        assertTrue(
            hook.checkAction(address(share), _action(VaultActionKind.DepositRequest, controller, owner, controller))
        );

        // RedeemClaim payout receiver must be a strict member (endorsement does not substitute).
        root.setEndorsed(endorsed, true);
        assertFalse(hook.checkAction(address(share), _action(VaultActionKind.RedeemClaim, owner, address(0), endorsed)));
        _member(receiver);
        assertTrue(
            hook.checkAction(address(share), _action(VaultActionKind.RedeemClaim, receiver, address(0), receiver))
        );
    }

    // --- Request transfers (ERC-8161): the transferee is held to the bar of the request it takes over ---

    function testRequestTransfers() public {
        ShareTokenHook full = _deploy(HookPolicies.fullRestrictions());
        ShareTokenHook freely = _deploy(HookPolicies.freelyTransferable());
        ShareTokenHook redemption = _deploy(HookPolicies.redemptionRestrictions());
        ShareTokenHook freezeOnly = _deploy(HookPolicies.freezeOnly());
        ShareTokenHook[4] memory all = [full, freely, redemption, freezeOnly];

        VaultAction memory depositTo = _action(VaultActionKind.DepositRequestTransfer, owner, owner, receiver);
        VaultAction memory redeemTo = _action(VaultActionKind.RedeemRequestTransfer, owner, owner, receiver);
        VaultAction memory depositToEndorsed = _action(VaultActionKind.DepositRequestTransfer, owner, owner, endorsed);
        VaultAction memory redeemToEndorsed = _action(VaultActionKind.RedeemRequestTransfer, owner, owner, endorsed);
        root.setEndorsed(endorsed, true);

        // A non-member transferee: only the flavors that do not gate that side let it through.
        assertFalse(full.checkAction(address(share), depositTo));
        assertFalse(freely.checkAction(address(share), depositTo));
        assertTrue(redemption.checkAction(address(share), depositTo));
        assertTrue(freezeOnly.checkAction(address(share), depositTo));
        assertFalse(full.checkAction(address(share), redeemTo));
        assertFalse(freely.checkAction(address(share), redeemTo));
        assertFalse(redemption.checkAction(address(share), redeemTo));
        assertTrue(freezeOnly.checkAction(address(share), redeemTo));

        // Endorsement substitutes for membership on a deposit position, not on a redeem position,
        // matching the request kinds.
        assertTrue(full.checkAction(address(share), depositToEndorsed));
        assertTrue(freely.checkAction(address(share), depositToEndorsed));
        assertFalse(full.checkAction(address(share), redeemToEndorsed));
        assertFalse(freely.checkAction(address(share), redeemToEndorsed));
        assertFalse(redemption.checkAction(address(share), redeemToEndorsed));

        // A member transferee passes everywhere; the source needs no membership to give a position up.
        _member(receiver);
        for (uint256 i; i < all.length; i++) {
            assertTrue(all[i].checkAction(address(share), depositTo));
            assertTrue(all[i].checkAction(address(share), redeemTo));
        }

        // A freeze on either side blocks both kinds in every flavor.
        _frozen(owner);
        for (uint256 i; i < all.length; i++) {
            assertFalse(all[i].checkAction(address(share), depositTo));
            assertFalse(all[i].checkAction(address(share), redeemTo));
        }
        _member(owner);
        _frozen(receiver);
        for (uint256 i; i < all.length; i++) {
            assertFalse(all[i].checkAction(address(share), depositTo));
            assertFalse(all[i].checkAction(address(share), redeemTo));
        }
    }

    // --- Ordering: FreezeOnly allows a superset of RedemptionRestrictions, which allows a superset of
    //     both FullRestrictions and FreelyTransferable. The last two are not ordered: Full gates who
    //     may hold, Freely who may exit, so they differ on the redeem claim (and the instant redemption
    //     that includes it) and agree elsewhere. ---

    function _setStatus(address user, uint8 status) internal {
        status = status % 7;
        if (status == 1) _member(user);
        else if (status == 2) root.setEndorsed(user, true);
        else if (status == 3) _frozen(user);
        else if (status == 4) _escrow(user, POOL);
        else if (status == 5) _vault(user, POOL, address(share));
        else if (status == 6) _vault(user, OTHER_POOL, makeAddr("otherShare"));
    }

    function _escrow(address user, PoolId poolId) internal {
        escrowProvider.setEscrow(poolId, user);
    }

    /// @dev A linked vault of `poolId`'s share class `SC`, which issues `token`, carrying a freeze bit set
    ///      before it was linked (as its predictable address allows).
    function _vault(address user, PoolId poolId, address token) internal {
        registry.setShareToken(poolId, SC, token);
        registry.setVault(user, poolId, SC, true);
        share.setHookData(user, bytes16(uint128(1)));
    }

    function testFlavorOrdering(
        uint8 kind_,
        uint8 controllerStatus,
        uint8 ownerStatus,
        uint8 receiverStatus,
        uint8 shape
    ) public {
        VaultActionKind kind = VaultActionKind(bound(kind_, 0, uint8(type(VaultActionKind).max)));
        // Party slots may coincide, as they do on the vault's own calls.
        address controller_ = controller;
        address owner_ = shape % 2 == 0 ? controller : owner;
        address receiver_ = shape % 3 == 0 ? controller : receiver;
        _setStatus(controller_, controllerStatus);
        if (owner_ != controller_) _setStatus(owner_, ownerStatus);
        if (receiver_ != controller_) _setStatus(receiver_, receiverStatus);
        VaultAction memory action = _action(kind, controller_, owner_, receiver_);

        bool freezeOnly = _deploy(HookPolicies.freezeOnly()).checkAction(address(share), action);
        bool redemption = _deploy(HookPolicies.redemptionRestrictions()).checkAction(address(share), action);
        bool full = _deploy(HookPolicies.fullRestrictions()).checkAction(address(share), action);
        bool freely = _deploy(HookPolicies.freelyTransferable()).checkAction(address(share), action);

        if (redemption) assertTrue(freezeOnly, "RedemptionRestrictions allowed what FreezeOnly blocks");
        if (full) assertTrue(redemption, "FullRestrictions allowed what RedemptionRestrictions blocks");
        if (freely) assertTrue(redemption, "FreelyTransferable allowed what RedemptionRestrictions blocks");
        assertEq(full, freely, "Full and Freely differ");
    }

    /// @dev An instant redemption is a redeem request and its claim at once, made by the caller for itself, so every
    ///      flavor allows it exactly when it allows both.
    function testInstantRedeemIsTheRequestAndItsClaim(uint8 controllerStatus, uint8 receiverStatus, uint8 shape)
        public
    {
        address controller_ = controller;
        address owner_ = controller;
        address receiver_ = shape % 3 == 0 ? controller : receiver;
        _setStatus(controller_, controllerStatus);
        if (receiver_ != controller_) _setStatus(receiver_, receiverStatus);

        uint8[4] memory flavors = [
            HookPolicies.freezeOnly(),
            HookPolicies.redemptionRestrictions(),
            HookPolicies.fullRestrictions(),
            HookPolicies.freelyTransferable()
        ];
        for (uint256 i; i < flavors.length; i++) {
            ShareTokenHook hook = _deploy(flavors[i]);
            bool request = hook.checkAction(
                address(share), _action(VaultActionKind.RedeemRequest, controller_, owner_, address(0))
            );
            bool claim =
                hook.checkAction(address(share), _action(VaultActionKind.RedeemClaim, controller_, owner_, receiver_));
            bool instant = hook.checkAction(
                address(share), _action(VaultActionKind.InstantRedeem, controller_, owner_, receiver_)
            );
            assertEq(instant, request && claim, "instant redeem is not the request and its claim");
        }
    }

    // --- Escrows count as members, as they do on the transfer path ---

    /// @dev A fund-of-funds claim (VaultLiquidityRoute, or a manager claiming an underlying redemption)
    ///      pays the top pool's escrow, which holds no membership on the underlying's token.
    function testRedeemClaimIntoEscrow() public {
        address route = makeAddr("route");
        address escrow = makeAddr("escrow");
        _member(route);
        VaultAction memory claim = _action(VaultActionKind.RedeemClaim, route, address(0), escrow);

        assertFalse(_deploy(HookPolicies.fullRestrictions()).checkAction(address(share), claim));
        assertFalse(_deploy(HookPolicies.freelyTransferable()).checkAction(address(share), claim));

        _escrow(escrow, OTHER_POOL);
        assertTrue(_deploy(HookPolicies.fullRestrictions()).checkAction(address(share), claim));
        assertTrue(_deploy(HookPolicies.freelyTransferable()).checkAction(address(share), claim));
        assertTrue(_deploy(HookPolicies.redemptionRestrictions()).checkAction(address(share), claim));
        assertTrue(_deploy(HookPolicies.freezeOnly()).checkAction(address(share), claim));
    }

    /// @dev The freeze bit on an escrow is ignored in a vault action, as `isSourceOrTargetFrozen` ignores
    ///      it on a transfer; `freeze` refuses escrows, so the bit can only predate the escrow.
    function testEscrowFreezeBitIsInert() public {
        address escrow = makeAddr("escrow");
        _escrow(escrow, POOL);
        share.setHookData(escrow, bytes16(uint128(1)));

        VaultAction memory claim = _action(VaultActionKind.RedeemClaim, controller, address(0), escrow);
        _member(controller);
        assertTrue(_deploy(HookPolicies.freelyTransferable()).checkAction(address(share), claim));
    }

    // --- Base onRoles: stateless enforcement (any caller), reverts when disallowed ---

    /// @dev One refused check refuses the batch, whatever its position, and an empty batch passes.
    function testOnRolesRefusesABatchWithOneFailingCheck() public {
        ShareTokenHook hook = _deploy(HookPolicies.freezeOnly());
        _frozen(controller);

        RoleCheck[] memory checks = new RoleCheck[](2);
        checks[0] = RoleCheck(Role.Entry, address(0), owner, 0, 0, Effect.Neutral);
        checks[1] = RoleCheck(Role.Entry, owner, controller, 0, 0, Effect.Neutral);
        assertFalse(hook.checkRoles(address(share), checks));
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        hook.onRoles(address(share), checks);

        assertTrue(hook.checkRoles(address(share), new RoleCheck[](0)));
    }

    function testOnRoleEnforces() public {
        ShareTokenHook hook = _deploy(HookPolicies.freezeOnly());
        RoleCheck[] memory checks = new RoleCheck[](1);
        checks[0] = RoleCheck(Role.Entry, owner, controller, 0, 0, Effect.Neutral);

        // Any caller may drive the stateless base; an allowed check passes and returns the selector the
        // vault requires.
        assertEq(hook.onRoles(address(share), checks), IRoleHook.onRoles.selector);

        // Disallowed check (frozen controller) reverts.
        _frozen(controller);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        hook.onRoles(address(share), checks);
    }

    /// @dev A deposit claim is one `DepositClaim` action. The delivery is an escrow to receiver transfer, so the
    ///      action adds the controller: it must be able to hold the shares itself, whoever the receiver is, so a
    ///      restricted controller cannot move its position to a clean address.
    function testADepositClaimNeedsAControllerThatCouldHoldIt() public {
        ShareTokenHook full = _deploy(HookPolicies.fullRestrictions());
        ShareTokenHook freeze = _deploy(HookPolicies.freezeOnly());
        _member(receiver);

        VaultAction memory toSelf = _action(VaultActionKind.DepositClaim, controller, address(0), controller);
        VaultAction memory toOther = _action(VaultActionKind.DepositClaim, controller, address(0), receiver);

        assertFalse(full.checkAction(address(share), toSelf), "a stranger controller cannot claim");
        assertFalse(full.checkAction(address(share), toOther), "a stranger controller cannot hand its claim on");
        assertTrue(freeze.checkAction(address(share), toOther), "no membership asked of an unfrozen controller");

        _member(controller);
        assertTrue(full.checkAction(address(share), toOther));

        _frozen(controller);
        assertFalse(full.checkAction(address(share), toOther), "a frozen controller cannot hand its claim on");
        assertFalse(freeze.checkAction(address(share), toOther));
    }

    /// @dev A refund returns what the controller put in, so a controller that was never a member, or lapsed, takes it
    ///      back to itself under every flavor. Only a freeze refuses it; the vault asks it only of a refund back to
    ///      the controller itself, and a refund to another receiver is a claim.
    function testRefundClaimNeedsOnlyAnUnfrozenController() public {
        uint8[4] memory flavors = [
            HookPolicies.freezeOnly(),
            HookPolicies.redemptionRestrictions(),
            HookPolicies.freelyTransferable(),
            HookPolicies.fullRestrictions()
        ];
        for (uint256 i; i < flavors.length; i++) {
            ShareTokenHook hook = _deploy(flavors[i]);

            share.setHookData(controller, bytes16(0));
            assertTrue(
                hook.checkAction(
                    address(share), _action(VaultActionKind.DepositRefundClaim, controller, address(0), controller)
                ),
                "a controller that is no member"
            );

            _frozen(controller);
            assertFalse(
                hook.checkAction(
                    address(share), _action(VaultActionKind.DepositRefundClaim, controller, address(0), controller)
                ),
                "a frozen controller"
            );
        }
    }

    /// @dev Who may fund a position credited to someone else is the vault's question, not the hook's.
    function testTheHookDoesNotGateWhoFundsAPosition() public {
        ShareTokenHook hook = _deploy(HookPolicies.freezeOnly());
        VaultActionKind[4] memory kinds = [
            VaultActionKind.DepositRequest,
            VaultActionKind.RedeemRequest,
            VaultActionKind.DepositRequestTransfer,
            VaultActionKind.RedeemRequestTransfer
        ];

        for (uint256 i; i < kinds.length; i++) {
            assertTrue(hook.checkAction(address(share), _action(kinds[i], owner, owner, controller)));
        }
    }
}
