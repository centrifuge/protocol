// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";

import {Role, RoleCheck, Effect} from "../../../src/token/interfaces/IRoleHook.sol";
import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @dev The reference hook (freeze only) with two limits on amounts: a holder's shares after an entry stay within
///      `entryCap`, by a vault action or a transfer, and one exit takes at most `exitCap` shares. It reports the room through `maxAllowed` when `reportsRoom`.
contract CappedShareTokenHook is ShareTokenHook {
    uint256 public immutable entryCap;
    uint256 public immutable exitCap;
    bool public immutable reportsRoom;

    constructor(ShareTokenHook base, uint256 entryCap_, uint256 exitCap_, bool reportsRoom_)
        ShareTokenHook(
            address(base.root()),
            base.envoy(),
            address(base.spokeRegistry()),
            address(base.spoke()),
            base.crosschainSource(),
            msg.sender,
            address(base.escrowProvider()),
            HookPolicies.freezeOnly()
        )
    {
        entryCap = entryCap_;
        exitCap = exitCap_;
        reportsRoom = reportsRoom_;
    }

    /// @dev A holder's transfer grows a position without a role check, so the cap applies to it here. A cross-chain
    ///      receipt does not: the source burned the shares, so refusing it would trap them. Issuance and escrow releases (`Kind.Mint`, `Kind.Release`) were counted on their role check, and
    ///      escrows, vaults and endorsed relays hold for others. The token calls back after it moved the shares, so
    ///      the callback reads the balance as it is, and the view, asked before, adds `value`.
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        view
        override
        returns (bytes4)
    {
        require(
            ShareTokenHook.checkERC20Transfer(from, to, value, hookData) && _transferWithinCap(from, to, 0),
            TransferBlocked()
        );
        return ITransferHook.onERC20Transfer.selector;
    }

    function checkERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        public
        view
        override
        returns (bool)
    {
        return super.checkERC20Transfer(from, to, value, hookData) && _transferWithinCap(from, to, value);
    }

    function _transferWithinCap(address from, address to, uint256 incoming) internal view returns (bool) {
        if (leg(from, to) != Kind.Transfer || from == crosschainSource || to == address(0) || isEscrow(to)) {
            return true;
        }
        if (root.endorsed(to) || isShareClassVault(msg.sender, to)) return true;
        return IERC20(msg.sender).balanceOf(to) + incoming <= entryCap;
    }

    function checkRole(address token, RoleCheck calldata c) public view override returns (bool) {
        return super.checkRole(token, c) && c.shares <= _room(token, c);
    }

    /// @dev Without `reportsRoom` it answers as the reference hook does, so a vault can only ask `checkRoles` at its
    ///      own capacity.
    function maxAllowed(address token, RoleCheck[] calldata checks)
        external
        view
        override
        returns (uint256 maxAssets, uint256 maxShares)
    {
        maxAssets = type(uint256).max;
        maxShares = type(uint256).max;
        if (!reportsRoom) return (maxAssets, maxShares);
        for (uint256 i; i < checks.length; i++) {
            uint256 room = _room(token, checks[i]);
            if (room < maxShares) maxShares = room;
        }
    }

    /// @dev The shares `c` may carry: the room under `entryCap` where an `Entry` grows `to`'s holding, `exitCap` on the
    ///      owner's exit (`Exit` from no one), no limit otherwise.
    function _room(address token, RoleCheck calldata c) internal view returns (uint256) {
        if (c.role == Role.Entry && (c.effect == Effect.Grows || c.effect == Effect.Moves)) {
            uint256 held = IERC20(token).balanceOf(c.to);
            return held >= entryCap ? 0 : entryCap - held;
        }
        if (c.role == Role.Exit && c.from == address(0)) return exitCap;
        return type(uint256).max;
    }
}
