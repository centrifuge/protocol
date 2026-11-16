// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Role} from "../interfaces/IRoleHook.sol";

/// @title  HookPolicies
/// @notice The flavors a `ShareTokenHook` is deployed as. A flavor is written as a `Policy` and encoded into the mask
///         the hook stores, one bit per role.
library HookPolicies {
    /// @notice Whether each role asks for membership, beyond not being frozen. How an endorsed contract counts is not
    ///         the flavor's choice: the roles that take or hold shares (`entry`, `transfer`) accept one, since it holds
    ///         shares mid-flow for the protocol, and the roles that leave the pool (`exit`, `burn`, `payout`) do not,
    ///         since an endorsed public relay would otherwise let anyone exit through it. An escrow counts as a member
    ///         in every role. `Refund` has no bit: only a freeze refuses it.
    /// @param entry Who takes shares, or a position that turns into shares.
    /// @param transfer Who takes shares from another holder, in a plain or cross-chain transfer.
    /// @param exit Who leaves the pool: gives up shares, or a position, to be redeemed.
    /// @param burn Who burns shares outside a redemption.
    /// @param payout Who receives the proceeds of a redemption.
    struct Policy {
        bool entry;
        bool transfer;
        bool exit;
        bool burn;
        bool payout;
    }

    /// @notice The mask a hook stores: the bit of each role that asks for membership, at the role's index in `Role`.
    function encode(Policy memory policy) internal pure returns (uint8) {
        return _bit(policy.entry, Role.Entry) | _bit(policy.transfer, Role.Transfer) | _bit(policy.exit, Role.Exit)
            | _bit(policy.burn, Role.Burn) | _bit(policy.payout, Role.Payout);
    }

    /// @notice Only the freeze bit gates anything.
    function freezeOnly() internal pure returns (uint8) {
        return encode(Policy({entry: false, transfer: false, exit: false, burn: false, payout: false}));
    }

    /// @notice Members only exit.
    function redemptionRestrictions() internal pure returns (uint8) {
        return encode(Policy({entry: false, transfer: false, exit: true, burn: false, payout: false}));
    }

    /// @notice Members only enter or exit the pool, and holders transfer freely among themselves.
    function freelyTransferable() internal pure returns (uint8) {
        return encode(Policy({entry: true, transfer: false, exit: true, burn: true, payout: true}));
    }

    /// @notice Members only hold, transfer, exit and are paid. A burn needs no membership.
    function fullRestrictions() internal pure returns (uint8) {
        return encode(Policy({entry: true, transfer: true, exit: true, burn: false, payout: true}));
    }

    function _bit(bool asked, Role role) private pure returns (uint8) {
        return asked ? uint8(1 << uint8(role)) : 0;
    }
}
