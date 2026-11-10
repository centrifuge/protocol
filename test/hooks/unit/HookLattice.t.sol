// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockEscrowProvider} from "../../core/mocks/MockEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";

import {MockVaultRegistry} from "../mocks/MockVaultRegistry.sol";

import "forge-std/Test.sol";

import {HookData} from "../../../src/token/interfaces/ITransferHook.sol";

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
/// @dev    The ordering holds everywhere except one documented pair. On the burn leg
///         (`Kind.Burn`, i.e. `to == 0`) FullRestrictions returns true unconditionally
///         while FreelyTransferable gates on source membership, so the looser hook is the stricter one.
///         That inversion is byte-identical to v3.1.0 and is left alone here rather than corrected in a
///         v3.3 regression fix: a holder whose membership lapses between request and claim is left with
///         neither the assets nor the shares until the pool re-adds them to the memberlist.
///
///         The carve-out is narrow on purpose - widen it and this test stops guarding a real pair - so
///         the exception stays visible and everything else is still checked.
contract HookLatticeTest is Test {
    ShareTokenHook full;
    ShareTokenHook freely;
    ShareTokenHook redemption;
    ShareTokenHook freeze;

    address spoke = makeAddr("spoke");
    address crosschainSource = makeAddr("crosschainSource");
    address escrow = makeAddr("escrow");
    address endorsedAddr = makeAddr("endorsed");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");
    address ownVault = makeAddr("ownVault");
    address foreignVault = makeAddr("foreignVault");

    address[] candidates;

    function setUp() public {
        LatticeRoot root = new LatticeRoot();
        root.endorse(endorsedAddr);

        MockEscrowProvider provider = new MockEscrowProvider();
        provider.setEscrow(PoolId.wrap(1), escrow);

        // The hooks are called directly, so this contract stands in for the share token: `ownVault` is a
        // linked vault of the share class it issues, `foreignVault` one of another pool's.
        MockVaultRegistry vaults = new MockVaultRegistry();
        ShareClassId sc = ShareClassId.wrap(bytes16("sc"));
        vaults.setShareToken(PoolId.wrap(1), sc, address(this));
        vaults.setShareToken(PoolId.wrap(2), sc, makeAddr("otherShare"));
        vaults.setVault(ownVault, PoolId.wrap(1), sc, true);
        vaults.setVault(foreignVault, PoolId.wrap(2), sc, true);
        address registry = address(vaults);
        address envoy = makeAddr("envoy");

        full = new ShareTokenHook(
            address(root),
            envoy,
            registry,
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.fullRestrictions()
        );
        freely = new ShareTokenHook(
            address(root),
            envoy,
            registry,
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.freelyTransferable()
        );
        redemption = new ShareTokenHook(
            address(root),
            envoy,
            registry,
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.redemptionRestrictions()
        );
        freeze = new ShareTokenHook(
            address(root),
            envoy,
            registry,
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.freezeOnly()
        );

        // One representative of every address role a classifier branches on
        candidates.push(address(0));
        candidates.push(spoke);
        candidates.push(crosschainSource);
        candidates.push(escrow);
        candidates.push(endorsedAddr);
        candidates.push(address(uint160(7))); // a centrifuge id encoded as an address
        candidates.push(holderA);
        candidates.push(holderB);
        candidates.push(ownVault);
        candidates.push(foreignVault);
    }

    function _pair(uint8 fromSel, uint8 toSel) internal view returns (address from, address to) {
        from = candidates[fromSel % candidates.length];
        to = candidates[toSel % candidates.length];
    }

    function _check(ShareTokenHook hook, address from, address to, HookData memory d) internal view returns (bool) {
        return hook.checkERC20Transfer(from, to, 1, d);
    }

    /// @dev The ordering itself, over every role pair and arbitrary membership and freeze bits.
    function testPermissivenessIsOrdered(uint8 fromSel, uint8 toSel, bytes16 hookFrom, bytes16 hookTo) public view {
        (address from, address to) = _pair(fromSel, toSel);
        HookData memory d = HookData(hookFrom, hookTo);

        _assertOrdered(from, to, d);
    }

    /// @dev The same ordering over unconstrained addresses, which reaches the generic branches.
    function testPolicyReadsBackThePresetADeploymentWasGiven() public view {
        _assertPolicy(full, HookPolicies.fullRestrictions());
        _assertPolicy(freely, HookPolicies.freelyTransferable());
        _assertPolicy(redemption, HookPolicies.redemptionRestrictions());
        _assertPolicy(freeze, HookPolicies.freezeOnly());
    }

    function _assertPolicy(ShareTokenHook hook, uint8 expected) internal view {
        assertEq(hook.policy(), expected);
    }

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

        // The documented inversion, described on the contract above
        if (full.leg(from, to) != IShareTokenHook.Kind.Burn) {
            if (fullOk) assertTrue(freelyOk, "FullRestrictions permits what FreelyTransferable does not");
        }
        if (freelyOk) assertTrue(redemptionOk, "FreelyTransferable permits what RedemptionRestrictions does not");
        if (redemptionOk) assertTrue(freezeOk, "RedemptionRestrictions permits what FreezeOnly does not");
    }

    /// @dev Every hookData consumer short-circuits on `isEscrow`, so an escrow's own entry is read
    ///      by no branch of any hook.
    function testEscrowMembershipIsInert(uint8 fromSel, uint8 toSel, bytes16 counterparty, uint64 validUntil)
        public
        view
    {
        (address from, address to) = _pair(fromSel, toSel);
        vm.assume(from == escrow || to == escrow);

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
        d.from = from == escrow ? escrowData : counterparty;
        d.to = to == escrow ? escrowData : counterparty;
    }

    /// @dev The one rule every hook shares: a frozen party blocks the transfer, unless it is a pool
    ///      escrow or a vault of the token's own share class, which are exempt on both legs so a freeze
    ///      cannot strand a pool's own custody.
    function testFreezeBindsEveryHook(uint8 fromSel, uint8 toSel, bool freezeFrom) public view {
        (address from, address to) = _pair(fromSel, toSel);
        bytes16 frozen = bytes16(uint128(1));

        HookData memory d = freezeFrom ? HookData(frozen, bytes16(0)) : HookData(bytes16(0), frozen);
        address party = freezeFrom ? from : to;
        vm.assume(party != escrow && party != ownVault);
        vm.assume(freezeFrom || party != address(0));

        assertFalse(_check(full, from, to, d), "FullRestrictions ignored a freeze");
        assertFalse(_check(freely, from, to, d), "FreelyTransferable ignored a freeze");
        assertFalse(_check(redemption, from, to, d), "RedemptionRestrictions ignored a freeze");
        assertFalse(_check(freeze, from, to, d), "FreezeOnly ignored a freeze");
    }

    /// @dev The freeze exemption of the token's own vault, which holds shares mid-revocation, is the
    ///      same in every hook. Another pool's vault gets none.
    function testOwnVaultFreezeBitIsInert(uint8 toSel, bytes16 counterparty) public view {
        address to = candidates[toSel % candidates.length];
        vm.assume(to != ownVault && to != foreignVault);
        HookData memory clean = HookData(bytes16(0), counterparty);
        HookData memory frozen = HookData(bytes16(uint128(1)), counterparty);

        assertEq(_check(full, ownVault, to, frozen), _check(full, ownVault, to, clean), "FullRestrictions");
        assertEq(_check(freely, ownVault, to, frozen), _check(freely, ownVault, to, clean), "FreelyTransferable");
        assertEq(
            _check(redemption, ownVault, to, frozen), _check(redemption, ownVault, to, clean), "RedemptionRestrictions"
        );
        assertEq(_check(freeze, ownVault, to, frozen), _check(freeze, ownVault, to, clean), "FreezeOnly");

        assertFalse(_check(freeze, foreignVault, to, frozen), "another pool's vault is exempt");
    }
}
