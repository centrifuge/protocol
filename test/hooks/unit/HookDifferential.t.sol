// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockRoot, MockShareToken} from "./ShareTokenHook.t.sol";

import {MockEscrowProvider} from "../../core/mocks/MockEscrowProvider.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";

import {VaultActionKind} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {MockVaultRegistry} from "../mocks/MockVaultRegistry.sol";
import {VaultAction, VaultActionCheck} from "../mocks/VaultActionCheck.sol";

import "forge-std/Test.sol";

import {LegacyFreezeOnly} from "../legacy/LegacyFreezeOnly.sol";
import {LegacyShareTokenHook} from "../legacy/LegacyShareTokenHook.sol";
import {HookData} from "../../../src/token/interfaces/ITransferHook.sol";
import {LegacyFullRestrictions} from "../legacy/LegacyFullRestrictions.sol";
import {LegacyFreelyTransferable} from "../legacy/LegacyFreelyTransferable.sol";
import {LegacyRedemptionRestrictions} from "../legacy/LegacyRedemptionRestrictions.sol";

/// @notice Differential test of the shipped hooks against a frozen copy of their pre-refactor code
///         (`test/hooks/legacy`). Every flavor, over every address role a classifier branches on and over
///         arbitrary membership and freeze bits, must answer exactly as the legacy hook does, for transfers and
///         for vault actions. It is the safety net for restructuring the hooks without changing what they allow.
contract HookDifferentialTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    PoolId constant OTHER_POOL = PoolId.wrap(2);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc"));

    MockShareToken share = new MockShareToken();
    ShareTokenHook[4] current;
    LegacyShareTokenHook[4] legacy;
    address[] candidates;

    address spoke = makeAddr("spoke");
    address crosschainSource = makeAddr("crosschainSource");
    address escrow = makeAddr("escrow");
    address endorsedAddr = makeAddr("endorsed");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");
    address ownVault = makeAddr("ownVault");
    address foreignVault = makeAddr("foreignVault");

    function setUp() public {
        MockRoot root = new MockRoot();
        root.setEndorsed(endorsedAddr, true);

        MockEscrowProvider provider = new MockEscrowProvider();
        provider.setEscrow(POOL, escrow);

        MockVaultRegistry registry = new MockVaultRegistry();
        registry.setShareToken(POOL, SC, address(share));
        registry.setShareToken(OTHER_POOL, SC, makeAddr("otherShare"));
        registry.setVault(ownVault, POOL, SC, true);
        registry.setVault(foreignVault, OTHER_POOL, SC, true);

        address envoy = makeAddr("envoy");
        current[0] = new ShareTokenHook(
            address(root),
            envoy,
            address(registry),
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.fullRestrictions()
        );
        current[1] = new ShareTokenHook(
            address(root),
            envoy,
            address(registry),
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.freelyTransferable()
        );
        current[2] = new ShareTokenHook(
            address(root),
            envoy,
            address(registry),
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.redemptionRestrictions()
        );
        current[3] = new ShareTokenHook(
            address(root),
            envoy,
            address(registry),
            spoke,
            crosschainSource,
            address(this),
            address(provider),
            HookPolicies.freezeOnly()
        );
        legacy[0] = new LegacyFullRestrictions(
            address(root), envoy, address(registry), spoke, crosschainSource, address(this), address(provider)
        );
        legacy[1] = new LegacyFreelyTransferable(
            address(root), envoy, address(registry), spoke, crosschainSource, address(this), address(provider)
        );
        legacy[2] = new LegacyRedemptionRestrictions(
            address(root), envoy, address(registry), spoke, crosschainSource, address(this), address(provider)
        );
        legacy[3] = new LegacyFreezeOnly(
            address(root), envoy, address(registry), spoke, crosschainSource, address(this), address(provider)
        );

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

    function _role(uint8 selector) internal view returns (address) {
        return candidates[selector % candidates.length];
    }

    //----------------------------------------------------------------------------------------------
    // Transfers
    //----------------------------------------------------------------------------------------------

    /// @dev The zero address cannot be frozen in a deployment, and a burn or fulfillment never asks about it as the
    ///      receiver, so that case carries no hook data.
    function _sameTransfer(address from, address to, HookData memory d) internal {
        if (to == address(0)) d.to = bytes16(0);

        for (uint256 i; i < 4; i++) {
            vm.prank(address(share));
            bool now_ = current[i].checkERC20Transfer(from, to, 1, d);
            vm.prank(address(share));
            bool then_ = legacy[i].checkERC20Transfer(from, to, 1, d);
            assertEq(now_, then_, string.concat("transfer differs in flavor ", vm.toString(i)));
        }
    }

    function testTransfersMatchOverEveryAddressRole(uint8 fromSel, uint8 toSel, bytes16 hookFrom, bytes16 hookTo)
        public
    {
        _sameTransfer(_role(fromSel), _role(toSel), HookData(hookFrom, hookTo));
    }

    function testTransfersMatchOverAnyAddress(address from, address to, bytes16 hookFrom, bytes16 hookTo) public {
        _sameTransfer(from, to, HookData(hookFrom, hookTo));
    }

    /// @dev Membership and freeze are read from `hookData`, so the interesting values are a live membership, a
    ///      lapsed one, none, and each with the freeze bit.
    function testTransfersMatchOverStructuredHookData(uint8 fromSel, uint8 toSel, uint8 fromState, uint8 toState)
        public
    {
        _sameTransfer(_role(fromSel), _role(toSel), HookData(_state(fromState), _state(toState)));
    }

    function _state(uint8 state) internal view returns (bytes16) {
        uint128 member = uint128(uint64(block.timestamp + 1 days)) << 64;
        uint128 lapsed = uint128(uint64(block.timestamp > 0 ? block.timestamp - 1 : 0)) << 64;
        uint8 kind = state % 6;
        if (kind == 0) return bytes16(0);
        if (kind == 1) return bytes16(member);
        if (kind == 2) return bytes16(lapsed);
        if (kind == 3) return bytes16(member | 1);
        if (kind == 4) return bytes16(lapsed | 1);
        return bytes16(uint128(1));
    }

    /// @dev The single classification reads off the same endpoints the legacy classifiers did, in their order.
    function testLegMatchesLegacyClassifiers(uint8 fromSel, uint8 toSel) public view {
        address from = _role(fromSel);
        address to = _role(toSel);
        LegacyShareTokenHook old = legacy[0];
        IShareTokenHook.Kind got = current[0].leg(from, to);

        if (old.isIssuance(from, to)) {
            assertTrue(got == IShareTokenHook.Kind.Mint, "issuance");
        } else if (old.isDepositClaim(from, to)) {
            assertTrue(got == IShareTokenHook.Kind.Release, "claim");
        } else if (old.isRedeemFulfillment(from, to)) {
            assertTrue(got == IShareTokenHook.Kind.Fulfill, "fulfill");
        } else if (old.isRedeemClaimOrRevocation(from, to)) {
            assertTrue(got == IShareTokenHook.Kind.Burn, "burn");
        } else {
            assertTrue(got == IShareTokenHook.Kind.Transfer, "transfer");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Vault actions
    //----------------------------------------------------------------------------------------------

    /// @dev The parties as the vault names them: never the zero address as a controller or an owner, which a role
    ///      check reads as no source, and an instant trade and a request transfer act for the caller's own position.
    function _sameAction(VaultActionKind kind, address controller, address owner, address receiver) internal view {
        vm.assume(controller != address(0) && owner != address(0));
        bool own = kind == VaultActionKind.InstantDeposit || kind == VaultActionKind.InstantRedeem
            || kind == VaultActionKind.DepositRequestTransfer || kind == VaultActionKind.RedeemRequestTransfer;
        VaultAction memory action = VaultAction(kind, own ? owner : controller, owner, receiver, 1);
        for (uint256 i; i < 4; i++) {
            bool now_ = VaultActionCheck.checkAction(current[i], address(share), action);
            bool then_ = legacy[i].checkAction(address(share), action);
            // The deliberate changes, each only ever stricter: FullRestrictions no longer lets an endorsed contract
            // receive redemption proceeds, since endorsement counts for roles that hold shares, not for ones that
            // leave the pool; a deposit request refuses a frozen payer; and an instant deposit asks of its receiver
            // what the issuance leg already does.
            bool payout = kind == VaultActionKind.RedeemClaim || kind == VaultActionKind.InstantRedeem;
            bool stricter = kind == VaultActionKind.DepositRequest || kind == VaultActionKind.InstantDeposit;
            if ((i == 0 && payout) || stricter) {
                assertTrue(!now_ || then_, "looser than before");
            } else {
                assertEq(now_, then_, string.concat("action differs in flavor ", vm.toString(i)));
            }
        }
    }

    function testActionsMatchOverEveryAddressRoleAndState(
        uint8 kindSel,
        uint8 controllerSel,
        uint8 ownerSel,
        uint8 receiverSel,
        uint8 controllerState,
        uint8 ownerState,
        uint8 receiverState
    ) public {
        address controller = _role(controllerSel);
        address owner = _role(ownerSel);
        address receiver = _role(receiverSel);
        // Later writes win when two parties coincide, the same for both hooks.
        share.setHookData(controller, _state(controllerState));
        share.setHookData(owner, _state(ownerState));
        share.setHookData(receiver, _state(receiverState));

        _sameAction(_legacyKind(kindSel), controller, owner, receiver);
    }

    function testActionsMatchOverAnyAddress(
        uint8 kindSel,
        address controller,
        address owner,
        address receiver,
        bytes16 controllerData,
        bytes16 ownerData,
        bytes16 receiverData
    ) public {
        share.setHookData(controller, controllerData);
        share.setHookData(owner, ownerData);
        share.setHookData(receiver, receiverData);

        _sameAction(_legacyKind(kindSel), controller, owner, receiver);
    }

    /// @dev The legacy hooks predate `DepositClaim`, so the kinds drawn are every other one.
    function _legacyKind(uint8 selector) internal pure returns (VaultActionKind) {
        uint8 kind = selector % 7;
        return VaultActionKind(kind < uint8(VaultActionKind.DepositClaim) ? kind : kind + 1);
    }
}
