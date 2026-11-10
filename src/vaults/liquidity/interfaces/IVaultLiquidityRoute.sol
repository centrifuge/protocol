// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

import {ILiquidityRoute} from "../../policies/interfaces/IVaultPlugins.sol";

/// @notice Liquidity route backing a fund-of-funds vault's instant redemptions with the positions its
///         pool holds in other vaults.
interface IVaultLiquidityRoute is ILiquidityRoute, IManagerCallFromHub, IRecoverable {
    /// @notice What a `fromHub` payload configures, `abi.encode(ConfigKind kind, address vault, bytes args)`:
    ///         `Routes` for a routing pool's top-level `vault`, with `args = abi.encode(address[] underlying)`,
    ///         and `Consent` for an underlying pool's `vault`, with
    ///         `args = abi.encode(address routingVault, bool allowed)`.
    enum ConfigKind {
        Routes,
        Consent
    }

    event SetRoutes(PoolId indexed poolId, address indexed vault, address[] underlying);
    /// @notice `underlying`'s pool, `poolId`, allowed or stopped routing from `vault`, a vault of another pool.
    event SetConsent(PoolId indexed poolId, address indexed vault, address indexed underlying, bool allowed);

    /// @notice `assets` were asked of `underlying` for `vault`, and `received` arrived, which is at least that.
    ///         `shares` is the amount `previewWithdraw` quoted for them, which the draw releases from the escrow;
    ///         `residualShares` of it came back unburned and were re-noted to the escrow, so the shares burned are
    ///         `shares - residualShares`. `value` is what those burned shares were worth at the underlying's own price
    ///         (`convertToAssets`, before its exit fee), or zero where it gave no price, so the draw cost the pool
    ///         `value - received`: the underlying's fee and rounding, or a gain where it is negative. Reported, not
    ///         used. A draw can be larger than the exit that made it: an exit drawing from the route also draws what
    ///         a manager reserved beyond the escrow's total, which the escrow needs covered before it pays anyone, so
    ///         the cost of that part is the pool's. An instant policy pricing its exit fee from this event spreads
    ///         that cost over exits rather than charging it to the one exit that drew it.
    event VaultRouteProvided(
        PoolId indexed poolId,
        address indexed vault,
        address indexed underlying,
        uint128 assets,
        uint256 received,
        uint256 shares,
        uint256 residualShares,
        uint256 value
    );

    /// @notice Only the Envoy may configure the route.
    error NotEnvoy();

    /// @notice Only the vault itself may draw through the route.
    error NotVault();

    /// @notice An underlying's pool has not consented to the vault routing through it.
    error NotConsented();

    /// @notice A vault cannot route through itself.
    error SelfRoute();

    /// @notice The list names an underlying vault twice, or two vaults on one share class, whose position it would count
    ///         twice.
    error DuplicateRoute();

    /// @notice The vault is not one of the configuring pool's vaults.
    error WrongPool();

    /// @notice An underlying is not a linked vault in the spoke registry.
    error UnknownVault();

    /// @notice An underlying takes a different asset than the vault.
    error AssetMismatch();

    /// @notice Configuration takes no native value.
    error UnexpectedValue();

    /// @notice The routes could not raise the full amount asked for.
    error InsufficientLiquidity();

    /// @notice The underlying vaults a top-level vault draws on, in the order they are drawn. Set
    ///         through the Envoy (`fromHub`, kind `Routes`), replacing the whole list. A vault can only route
    ///         through an underlying whose own pool consented to it.
    function routes(address vault) external view returns (address[] memory);

    /// @notice Whether the pool of `underlying` lets `vault` draw on it through this route. The route is one
    ///         caller for every pool, so the underlying cannot tell them apart: this is its consent, set through
    ///         the Envoy (`fromHub`, kind `Consent`) by the underlying's own pool.
    function isConsented(address underlying, address vault) external view returns (bool);
}
