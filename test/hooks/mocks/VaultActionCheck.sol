// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// The library's action carries assets and shares apart; the hook tests use one amount for both

import {
    VaultActionLib,
    VaultActionKind,
    VaultAction as LibAction
} from "../../../src/vaults/libraries/VaultActionLib.sol";

import {IRoleHook} from "../../../src/token/interfaces/IRoleHook.sol";

struct VaultAction {
    VaultActionKind kind;
    address controller;
    address owner;
    address receiver;
    /// @dev Both the assets and the shares the checks carry
    uint128 amount;
}

/// @dev Asks a hook about a vault action the way the vault does, through the role checks `VaultActionLib` maps it to,
///      so the hook tests read in the vault's terms.
library VaultActionCheck {
    function checkAction(IRoleHook hook, address token, VaultAction memory action) internal view returns (bool) {
        return hook.checkRoles(
            token,
            VaultActionLib.roleChecks(
                LibAction(action.kind, action.controller, action.owner, action.receiver, action.amount, action.amount)
            )
        );
    }

    function onAction(IRoleHook hook, address token, VaultAction memory action) internal {
        bytes4 answer = hook.onRoles(
            token,
            VaultActionLib.roleChecks(
                LibAction(action.kind, action.controller, action.owner, action.receiver, action.amount, action.amount)
            )
        );
        require(answer == IRoleHook.onRoles.selector);
    }
}
