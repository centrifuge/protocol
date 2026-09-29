// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockEscrowProvider} from "../../core/mocks/MockEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";

import {FreezeOnly} from "../../../src/token/hooks/FreezeOnly.sol";
import {BaseTransferHook} from "../../../src/token/hooks/BaseTransferHook.sol";
import {FullRestrictions} from "../../../src/token/hooks/FullRestrictions.sol";
import {FreelyTransferable} from "../../../src/token/hooks/FreelyTransferable.sol";
import {RedemptionRestrictions} from "../../../src/token/hooks/RedemptionRestrictions.sol";

import "forge-std/Test.sol";

import {HookData, ESCROW_HOOK_ID} from "../../../src/token/interfaces/ITransferHook.sol";

contract LatticeRoot {
    mapping(address => bool) public endorsed;

    function endorse(address user) external {
        endorsed[user] = true;
    }
}

/// @title  HookLatticeTest
/// @notice The four shipped hooks are meant to be strictly ordered by permissiveness:
///
///             FullRestrictions ⊆ FreelyTransferable ⊆ RedemptionRestrictions ⊆ FreezeOnly
///
///         Each one gates everything the next one does and more, so anything a stricter hook permits a
///         looser hook must also permit. A pool moving to a looser hook should never find a flow that
///         stops working, and a classifier added to one hook but not the others is how that breaks.
///
/// @dev    The ordering holds everywhere except two documented pairs. On the burn leg
///         (`isRedeemClaimOrRevocation`, i.e. `to == 0`) FullRestrictions returns true unconditionally
///         while FreelyTransferable gates on source membership, so the looser hook is the stricter one.
///         That inversion is byte-identical to v3.1.0 and is left alone here rather than corrected in a
///         v3.3 regression fix; see HookClaimLifecycleTest for what it costs a holder.
///
///         The second is `(address(0), ESCROW_HOOK_ID)`, the only pair two classifiers both claim:
///         `isRedeemRequest` ignores `from`, so it overlaps `isDepositRequestOrIssuance` there. The hooks
///         resolve the overlap in opposite orders - FreelyTransferable and FullRestrictions try issuance
///         first and check the target, RedemptionRestrictions only has the redeem-request branch and
///         checks the source - so the ordering inverts. No caller produces the pair: a redeem request
///         moves a holder's own shares (`ITransferHook` documents the leg as `address(user)` ->
///         `ESCROW_HOOK_ID`), never freshly minted ones, and `ESCROW_HOOK_ID` is a sentinel nothing mints
///         to.
///
///         Both carve-outs are narrow on purpose - widen either and this test stops guarding a real pair -
///         so the exceptions stay visible and everything else is still checked.
contract HookLatticeTest is Test {
    FullRestrictions full;
    FreelyTransferable freely;
    RedemptionRestrictions redemption;
    FreezeOnly freeze;

    address spoke = makeAddr("spoke");
    address crosschainSource = makeAddr("crosschainSource");
    address poolEscrow = makeAddr("poolEscrow");
    address endorsedAddr = makeAddr("endorsed");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");

    address[] candidates;

    function setUp() public {
        LatticeRoot root = new LatticeRoot();
        root.endorse(endorsedAddr);

        MockEscrowProvider provider = new MockEscrowProvider();
        provider.setEscrow(PoolId.wrap(1), poolEscrow);

        address registry = makeAddr("spokeRegistry");
        address envoy = makeAddr("envoy");

        full = new FullRestrictions(
            address(root), envoy, registry, spoke, crosschainSource, address(this), address(provider)
        );
        freely = new FreelyTransferable(
            address(root), envoy, registry, spoke, crosschainSource, address(this), address(provider)
        );
        redemption = new RedemptionRestrictions(
            address(root), envoy, registry, spoke, crosschainSource, address(this), address(provider)
        );
        freeze =
            new FreezeOnly(address(root), envoy, registry, spoke, crosschainSource, address(this), address(provider));

        // One representative of every address role a classifier branches on
        candidates.push(address(0));
        candidates.push(spoke);
        candidates.push(crosschainSource);
        candidates.push(poolEscrow);
        candidates.push(ESCROW_HOOK_ID);
        candidates.push(endorsedAddr);
        candidates.push(address(uint160(7))); // a centrifuge id encoded as an address
        candidates.push(holderA);
        candidates.push(holderB);
    }

    function _pair(uint8 fromSel, uint8 toSel) internal view returns (address from, address to) {
        from = candidates[fromSel % candidates.length];
        to = candidates[toSel % candidates.length];
    }

    function _check(BaseTransferHook hook, address from, address to, HookData memory d) internal view returns (bool) {
        return hook.checkERC20Transfer(from, to, 1, d);
    }

    /// @dev The ordering itself, over every role pair and arbitrary membership and freeze bits.
    function testPermissivenessIsOrdered(uint8 fromSel, uint8 toSel, bytes16 hookFrom, bytes16 hookTo) public view {
        (address from, address to) = _pair(fromSel, toSel);
        HookData memory d = HookData(hookFrom, hookTo);

        _assertOrdered(from, to, d);
    }

    /// @dev The same ordering over unconstrained addresses, which reaches the generic branches.
    function testPermissivenessIsOrderedForAnyAddresses(address from, address to, bytes16 hookFrom, bytes16 hookTo)
        public
        view
    {
        HookData memory d = HookData(hookFrom, hookTo);

        _assertOrdered(from, to, d);
    }

    function _assertOrdered(address from, address to, HookData memory d) internal view {
        bool fullOk = _check(full, from, to, d);
        bool freelyOk = _check(freely, from, to, d);
        bool redemptionOk = _check(redemption, from, to, d);
        bool freezeOk = _check(freeze, from, to, d);

        // The two documented inversions, described on the contract above
        if (!full.isRedeemClaimOrRevocation(from, to)) {
            if (fullOk) assertTrue(freelyOk, "FullRestrictions permits what FreelyTransferable does not");
        }
        if (from != address(0) || to != ESCROW_HOOK_ID) {
            if (freelyOk) assertTrue(redemptionOk, "FreelyTransferable permits what RedemptionRestrictions does not");
        }
        if (redemptionOk) assertTrue(freezeOk, "RedemptionRestrictions permits what FreezeOnly does not");
    }

    /// @dev Pins the second carve-out rather than only excluding it: `(address(0), ESCROW_HOOK_ID)` is
    ///      claimed by two classifiers and the hooks disagree on which one wins. Resolve that overlap and
    ///      this fails, which is the signal to drop the carve-out in {_assertOrdered} with it.
    function testMintIntoTheRedeemSentinelIsClaimedByTwoClassifiers() public view {
        // A member target, a non-member source
        HookData memory d = HookData(bytes16(0), bytes16(uint128(type(uint64).max) << 64));

        assertTrue(full.isDepositRequestOrIssuance(address(0), ESCROW_HOOK_ID), "not an issuance");
        assertTrue(full.isRedeemRequest(address(0), ESCROW_HOOK_ID), "not a redeem request");

        assertTrue(_check(freely, address(0), ESCROW_HOOK_ID, d), "FreelyTransferable stopped checking the target");
        assertFalse(
            _check(redemption, address(0), ESCROW_HOOK_ID, d), "RedemptionRestrictions stopped checking the source"
        );
    }

    /// @dev Every hookData consumer short-circuits on `isPoolEscrow`, so an escrow's own entry is read
    ///      by no branch of any hook.
    function testPoolEscrowMembershipIsInert(uint8 fromSel, uint8 toSel, bytes16 counterparty, uint64 validUntil)
        public
        view
    {
        (address from, address to) = _pair(fromSel, toSel);
        vm.assume(from == poolEscrow || to == poolEscrow);

        bytes16 entry = bytes16(uint128(validUntil) << 64);
        HookData memory without_ = _escrowData(from, to, bytes16(0), counterparty);
        HookData memory with_ = _escrowData(from, to, entry, counterparty);

        assertEq(_check(full, from, to, with_), _check(full, from, to, without_), "FullRestrictions");
        assertEq(_check(freely, from, to, with_), _check(freely, from, to, without_), "FreelyTransferable");
        assertEq(_check(redemption, from, to, with_), _check(redemption, from, to, without_), "RedemptionRestrictions");
        assertEq(_check(freeze, from, to, with_), _check(freeze, from, to, without_), "FreezeOnly");
    }

    /// @dev Control: inertness above would also hold if the harness saw no membership at all.
    function testMembershipBindsANonEscrowTarget() public view {
        bytes16 member = bytes16(uint128(type(uint64).max) << 64);

        assertFalse(_check(full, holderA, holderB, HookData(bytes16(0), bytes16(0))), "a non-member target passed");
        assertTrue(_check(full, holderA, holderB, HookData(bytes16(0), member)), "a member target was refused");
    }

    function _escrowData(address from, address to, bytes16 escrowData, bytes16 counterparty)
        internal
        view
        returns (HookData memory d)
    {
        d.from = from == poolEscrow ? escrowData : counterparty;
        d.to = to == poolEscrow ? escrowData : counterparty;
    }

    /// @dev The one rule every hook shares: a frozen party blocks the transfer, unless it is a pool
    ///      escrow, which is exempt on both legs so a freeze cannot strand a pool's own custody.
    function testFreezeBindsEveryHook(uint8 fromSel, uint8 toSel, bool freezeFrom) public view {
        (address from, address to) = _pair(fromSel, toSel);
        bytes16 frozen = bytes16(uint128(1));

        HookData memory d = freezeFrom ? HookData(frozen, bytes16(0)) : HookData(bytes16(0), frozen);
        address party = freezeFrom ? from : to;
        vm.assume(party != poolEscrow);

        assertFalse(_check(full, from, to, d), "FullRestrictions ignored a freeze");
        assertFalse(_check(freely, from, to, d), "FreelyTransferable ignored a freeze");
        assertFalse(_check(redemption, from, to, d), "RedemptionRestrictions ignored a freeze");
        assertFalse(_check(freeze, from, to, d), "FreezeOnly ignored a freeze");
    }
}
