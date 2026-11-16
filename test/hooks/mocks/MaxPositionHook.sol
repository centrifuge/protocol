// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";

import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {IRoleHook, Role, RoleCheck, Effect} from "../../../src/token/interfaces/IRoleHook.sol";

/// @dev A role hook that limits a position (see `Effect`) across the token's vaults, and knows nothing of vault
///      actions: it reads each check's `shares` and `effect`. Only what grows a position, or moves one to `to`, is
///      limited, so a holder over its limit can still claim, exit and take a refund. The limit is per account, where
///      a real hook could group wallets.
///
///      What it costs and covers: a check reads four views per vault (one reads the oracle, three walk the
///      horizon) for each wallet it sums, and the instant `max*` views pay it twice, through `maxAllowed` and
///      `checkRoles`. It counts the vaults it was given and no others, so the list has to follow every vault linked
///      to the share class, and it counts one chain: a cap is per chain.
contract MaxPositionHook is IRoleHook {
    error MaxPositionExceeded();

    uint256 public immutable cap;
    address[] public vaults;

    constructor(uint256 cap_, address[] memory vaults_) {
        cap = cap_;
        vaults = vaults_;
    }

    function onRoles(address token, RoleCheck[] calldata checks) external view returns (bytes4) {
        require(checkRoles(token, checks), MaxPositionExceeded());
        return IRoleHook.onRoles.selector;
    }

    function checkRoles(address token, RoleCheck[] calldata checks) public view returns (bool) {
        for (uint256 i; i < checks.length; i++) {
            if (checks[i].shares > _room(token, checks[i])) return false;
        }
        return true;
    }

    function maxAllowed(address token, RoleCheck[] calldata checks)
        external
        view
        returns (uint256 maxAssets, uint256 maxShares)
    {
        maxAssets = type(uint256).max;
        maxShares = type(uint256).max;
        for (uint256 i; i < checks.length; i++) {
            uint256 room = _room(token, checks[i]);
            if (room < maxShares) maxShares = room;
        }
    }

    /// @dev Shares held, plus pending deposits at the vault's price, claimable shares and pending redemptions.
    function position(address token, address who) public view returns (uint256 total) {
        total = IERC20(token).balanceOf(who);
        for (uint256 i; i < vaults.length; i++) {
            IAsyncVault v = IAsyncVault(vaults[i]);
            total += v.convertToShares(v.pendingDepositRequest(0, who)) + v.claimableMint(who)
            + v.pendingRedeemRequest(0, who);
        }
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == type(IRoleHook).interfaceId || id == type(IERC165).interfaceId;
    }

    /// @dev The shares `c` may carry: the room under the cap where an `Entry` grows `to`'s position, no limit
    ///      otherwise. A redemption moved to `to` (`Exit`) is never refused, so an omnibus controller's owners can
    ///      still leave; a cancellation brings it back as claimable shares, which a manager has to trigger.
    function _room(address token, RoleCheck calldata c) internal view returns (uint256) {
        if (c.role != Role.Entry || (c.effect != Effect.Grows && c.effect != Effect.Moves)) return type(uint256).max;
        uint256 held = position(token, c.to);
        return held >= cap ? 0 : cap - held;
    }
}
