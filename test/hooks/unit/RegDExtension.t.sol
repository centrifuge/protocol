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

import {Role} from "../../../src/token/interfaces/IRoleHook.sol";
import {HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @dev A bespoke hook: the full-restrictions policy plus a per-investor class in bit 1 of the hook data, where a party may
///      only give shares or a position to a party of the same class (a Reg D investor to another Reg D investor).
///      Every relation between two parties, a transfer or a role check the vault asks, reaches the hook as the two
///      ends of a hand-over, so the rule is one function over them.
contract RegDHook is ShareTokenHook {
    uint8 internal constant CLASS_INDEX = 1;
    uint128 internal constant CLASS_BIT = 2;

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
            HookPolicies.fullRestrictions()
        )
    {}

    /// @dev A manager marks an investor as Reg D, keeping the membership and freeze bits.
    function setRegD(address token, address user, bool regD) external authOrManager(token) {
        _setHookBit(token, user, CLASS_INDEX, regD);
    }

    /// @dev One rule for every hand-over: whoever gives, to whoever receives, must share a class.
    function _canHandOver(address token, Role role, HookData memory data, address from, address to)
        internal
        view
        override
        returns (bool)
    {
        if (!super._canHandOver(token, role, data, from, to)) return false;

        // Mints, deliveries and the protocol's own movements have no investor on one side.
        if (from == address(0) || to == address(0) || isEscrow(from) || isEscrow(to)) return true;
        return (uint128(data.from) & CLASS_BIT) == (uint128(data.to) & CLASS_BIT);
    }
}

contract RegDExtensionTest is Test {
    using VaultActionCheck for *;

    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    uint128 constant CLASS_BIT = 2;

    MockShareToken share = new MockShareToken();
    RegDHook hook;

    address regDInvestor = makeAddr("regDInvestor");
    address otherRegDInvestor = makeAddr("otherRegDInvestor");
    address regSInvestor = makeAddr("regSInvestor");

    function setUp() public {
        MockRoot root = new MockRoot();
        MockEscrowProvider provider = new MockEscrowProvider();
        MockVaultRegistry registry = new MockVaultRegistry();
        registry.setShareToken(POOL, SC, address(share));

        hook = new RegDHook(
            address(root),
            makeAddr("envoy"),
            address(registry),
            makeAddr("spoke"),
            makeAddr("crosschainSource"),
            address(this),
            address(provider)
        );

        // Members all, two of them Reg D
        share.setHookData(regDInvestor, _member(CLASS_BIT));
        share.setHookData(otherRegDInvestor, _member(CLASS_BIT));
        share.setHookData(regSInvestor, _member(0));
    }

    function _member(uint128 classBits) internal view returns (bytes16) {
        return bytes16((uint128(uint64(block.timestamp + 365 days)) << 64) | classBits);
    }

    function _action(VaultActionKind kind, address controller, address owner, address receiver)
        internal
        pure
        returns (VaultAction memory)
    {
        return VaultAction(kind, controller, owner, receiver, 1);
    }

    /// @dev The two members of one class can do everything the base flavor allows; across classes nothing that
    ///      relates a giver to a receiver goes through, including the receiver-differs-from-caller cases of
    ///      `deposit`, `mint`, `withdraw`, `redeem` and the claims.
    function testActionsAcrossClassesAreRefused() public view {
        VaultActionKind[7] memory kinds = [
            VaultActionKind.DepositRequest,
            VaultActionKind.RedeemClaim,
            VaultActionKind.DepositClaim,
            VaultActionKind.InstantDeposit,
            VaultActionKind.InstantRedeem,
            VaultActionKind.DepositRequestTransfer,
            VaultActionKind.RedeemRequestTransfer
        ];

        for (uint256 i; i < kinds.length; i++) {
            VaultActionKind kind = kinds[i];
            // The giver is the owner. A deposit request relates it to its controller, every other kind to its receiver.
            bool isRequest = kind == VaultActionKind.DepositRequest;

            assertTrue(
                hook.checkAction(address(share), _pair(kind, isRequest, otherRegDInvestor)),
                string.concat("same class refused: ", vm.toString(uint8(kind)))
            );
            assertFalse(
                hook.checkAction(address(share), _pair(kind, isRequest, regSInvestor)),
                string.concat("cross class allowed: ", vm.toString(uint8(kind)))
            );
        }
    }

    function _pair(VaultActionKind kind, bool controllerIsOther, address other)
        internal
        view
        returns (VaultAction memory)
    {
        return controllerIsOther
            ? _action(kind, other, regDInvestor, address(0))
            : _action(kind, regDInvestor, regDInvestor, other);
    }

    function testPlainTransfersAcrossClassesAreRefused() public {
        HookData memory regDToRegD = HookData(share.hookDataOf(regDInvestor), share.hookDataOf(otherRegDInvestor));
        HookData memory regDToRegS = HookData(share.hookDataOf(regDInvestor), share.hookDataOf(regSInvestor));

        vm.startPrank(address(share));
        assertTrue(hook.checkERC20Transfer(regDInvestor, otherRegDInvestor, 1, regDToRegD));
        assertFalse(hook.checkERC20Transfer(regDInvestor, regSInvestor, 1, regDToRegS));
        vm.stopPrank();
    }

    /// @dev Marking an investor keeps the membership and the freeze bit, and a freeze keeps the class.
    function testMarkingAnInvestorKeepsEverythingElse() public {
        address newcomer = makeAddr("newcomer");
        share.setHookData(newcomer, _member(0));

        hook.setRegD(address(share), newcomer, true);
        assertEq(uint128(share.hookDataOf(newcomer)), uint128(_member(CLASS_BIT)));

        hook.freeze(address(share), newcomer);
        assertEq(uint128(share.hookDataOf(newcomer)), uint128(_member(CLASS_BIT)) | 1);

        hook.setRegD(address(share), newcomer, false);
        assertEq(uint128(share.hookDataOf(newcomer)), uint128(_member(0)) | 1);
    }

    /// @dev The class bit survives a membership renewal, which is what a compliance team does every year.
    function testTheClassSurvivesAMembershipUpdate() public {
        hook.updateMember(address(share), regDInvestor, uint64(block.timestamp + 730 days));

        assertEq(uint128(share.hookDataOf(regDInvestor)) & CLASS_BIT, CLASS_BIT);
        assertTrue(
            hook.checkAction(
                address(share), _action(VaultActionKind.InstantDeposit, regDInvestor, regDInvestor, otherRegDInvestor)
            )
        );
    }
}
