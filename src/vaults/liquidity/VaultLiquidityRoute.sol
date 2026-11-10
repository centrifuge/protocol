// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IVaultLiquidityRoute} from "./interfaces/IVaultLiquidityRoute.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {IERC7575} from "../../misc/interfaces/IERC7575.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {VaultDetails, ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IVault} from "../interfaces/IVault.sol";
import {IAsyncVault} from "../interfaces/IAsyncVault.sol";
import {IShareToken} from "../../token/interfaces/IShareToken.sol";
import {ILiquidityRoute} from "../policies/interfaces/IVaultPlugins.sol";

/// @title  Vault Liquidity Route
/// @notice Backs a fund-of-funds vault's instant redemptions with the positions its pool holds in
///         other vaults: when the escrow falls short, it redeems underlying positions in route order
///         and pays the proceeds to the vault.
/// @dev    Setup and trust assumptions are in SPECIFICATION.md ("Vault liquidity route", "Trust in pool-chosen
///         components"). The registry decides which tokens move; what an underlying answers is
///         checked, not trusted, so a misbehaving one costs at most the position in it.
contract VaultLiquidityRoute is Recoverable, IVaultLiquidityRoute {
    using MathLib for uint256;

    /// @dev What one quote into another pool's contract may spend. An underlying is another pool's vault, whose own
    ///      route can lead back here (two pools holding each other's shares), so its gas is not bounded by anything
    ///      the routing pool chose. A quote that runs out reads as no answer, like one that reverts.
    uint256 public constant QUOTE_GAS = 400_000;

    ISpoke public immutable spoke;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;

    mapping(address vault => address[]) internal _routes;
    mapping(address underlying => mapping(address vault => bool)) public isConsented;

    constructor(ISpoke spoke_, address envoy_, address root_) Auth(root_) {
        spoke = spoke_;
        envoy = envoy_;
        spokeRegistry = spoke_.spokeRegistry();
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (ConfigKind kind, address vault, bytes memory args) = abi.decode(payload, (ConfigKind, address, bytes));

        VaultDetails memory details = _details(vault);
        require(details.poolId == poolId && IVault(vault).poolId() == poolId, WrongPool());

        if (kind == ConfigKind.Routes) return _setRoutes(vault, details, args);
        _setConsent(poolId, vault, args);
    }

    //----------------------------------------------------------------------------------------------
    // Liquidity
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ILiquidityRoute
    function provide(address vault, uint128 assets) external {
        require(msg.sender == vault, NotVault());

        VaultDetails memory details = _details(vault);
        address escrow = address(spoke.escrow(details.poolId));
        address[] memory underlying = _routes[vault];

        uint128 remaining = assets;
        for (uint256 i; i < underlying.length && remaining > 0; i++) {
            (uint256 capacity, uint128 held, address shareToken) = _capacity(vault, details, escrow, underlying[i]);
            uint128 take = MathLib.min(remaining, capacity).toUint128();
            if (take == 0) continue;

            _redeem(vault, details, underlying[i], shareToken, take, held);
            remaining -= take;
        }

        require(remaining == 0, InsufficientLiquidity());
    }

    /// @inheritdoc ILiquidityRoute
    function forward(address, uint128) external pure {}

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultLiquidityRoute
    function routes(address vault) external view returns (address[] memory) {
        return _routes[vault];
    }

    /// @inheritdoc ILiquidityRoute
    function available(address vault) external view returns (uint128 assets) {
        VaultDetails memory details = _details(vault);

        // Releasing the pool's holdings takes the manager role, so without it nothing is drawable.
        if (!spokeRegistry.manager(details.poolId, address(this))) return 0;
        address escrow = address(spoke.escrow(details.poolId));
        address[] memory underlying = _routes[vault];

        uint256 total;
        for (uint256 i; i < underlying.length; i++) {
            (uint256 capacity,,) = _capacity(vault, details, escrow, underlying[i]);
            total += capacity;
        }

        return MathLib.min(total, type(uint128).max).toUint128();
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev The route counts the pool's position by share class, so two vaults on one share class (or one vault twice)
    ///      would each offer the whole position and `available` would count it twice.
    function _setRoutes(address vault, VaultDetails memory details, bytes memory args) internal {
        address[] memory underlying = abi.decode(args, (address[]));
        VaultDetails[] memory listed = new VaultDetails[](underlying.length);
        for (uint256 i; i < underlying.length; i++) {
            require(underlying[i] != vault, SelfRoute());
            VaultDetails memory route = _details(underlying[i]);
            for (uint256 j; j < i; j++) {
                require(!(listed[j].poolId == route.poolId && listed[j].scId == route.scId), DuplicateRoute());
            }
            listed[i] = route;
            require(route.isLinked, UnknownVault());
            require(route.asset == details.asset, AssetMismatch());
            require(isConsented[underlying[i]][vault], NotConsented());
        }

        _routes[vault] = underlying;
        emit SetRoutes(details.poolId, vault, underlying);
    }

    function _setConsent(PoolId poolId, address underlying, bytes memory args) internal {
        (address vault, bool allowed) = abi.decode(args, (address, bool));

        isConsented[underlying][vault] = allowed;
        emit SetConsent(poolId, vault, underlying, allowed);
    }

    /// @dev Releases enough of the pool's position in `underlying` to raise `assets` and pays the vault.
    function _redeem(
        address vault,
        VaultDetails memory details,
        address underlying,
        address shareToken,
        uint128 assets,
        uint128 held
    ) internal {
        // Rounded up to cover the burn, with any residual returned to the escrow; checked, as the quote is untrusted.
        uint256 shares = IAsyncVault(underlying).previewWithdraw(assets);
        require(shares <= held, InsufficientLiquidity());

        uint256 sharesBefore = IERC20(shareToken).balanceOf(address(this));
        uint256 assetsBefore = IERC20(details.asset).balanceOf(address(this));
        spoke.withdraw(details.poolId, details.scId, shareToken, 0, address(this), shares.toUint128());

        // Measured here, not at the escrow a reentrant deposit into a sibling vault can fill.
        SafeTransferLib.safeApprove(shareToken, underlying, shares);
        IAsyncVault(underlying).withdraw(assets, address(this));
        SafeTransferLib.safeApprove(shareToken, underlying, 0);

        uint256 received = IERC20(details.asset).balanceOf(address(this)) - assetsBefore;
        require(received >= assets, InsufficientLiquidity());
        SafeTransferLib.safeTransfer(details.asset, vault, received);

        // Only what this draw released goes back: the route serves every pool, so any other balance
        // it holds is not this pool's to re-note.
        uint256 sharesAfter = IERC20(shareToken).balanceOf(address(this));
        uint256 residual = sharesAfter > sharesBefore ? sharesAfter - sharesBefore : 0;
        if (residual > 0) {
            SafeTransferLib.safeTransfer(shareToken, address(spoke.escrow(details.poolId)), residual);
            spoke.noteDeposit(details.poolId, details.scId, shareToken, 0, residual.toUint128());
        }

        // Read through `_read`: what an untrusted underlying answers only colours the event
        (, uint256 value) = _read(underlying, abi.encodeCall(IERC7575.convertToAssets, (shares - residual)));
        emit VaultRouteProvided(details.poolId, vault, underlying, assets, received, shares, residual, value);
    }

    /// @dev What one route could raise: the underlying's instant capacity, bounded by what the pool's
    ///      position fetches there. Never reverts; a failed quote or release reads as zero. Bounded by
    ///      `previewRedeem`, the fee-aware inverse of the `previewWithdraw` that sizes the burn.
    function _capacity(address vault, VaultDetails memory details, address escrow, address underlying)
        internal
        view
        returns (uint256 capacity, uint128 held, address shareToken)
    {
        // The registry's token, never the underlying's own `share()`, which could name any token.
        VaultDetails memory route = _details(underlying);
        if (!route.isLinked || !isConsented[underlying][vault]) return (0, 0, address(0));
        shareToken = address(spokeRegistry.shareToken(route.poolId, route.scId));

        held = spoke.availableBalanceOf(details.poolId, details.scId, shareToken, 0);
        if (held == 0) return (0, 0, shareToken);

        (bool releasable, uint256 allowed) =
            _read(shareToken, abi.encodeCall(IShareToken.checkTransferRestriction, (escrow, address(this), held)));
        if (!releasable || allowed == 0) return (0, held, shareToken);

        // The route holds no underlying shares until it draws, so it asks for the capacity before its balance.
        (bool quoted, uint256 instant) =
            _read(underlying, abi.encodeCall(IAsyncVault.withdrawCapacity, (address(this))));
        if (!quoted || instant == 0) return (0, held, shareToken);
        (bool valued, uint256 backing) = _read(underlying, abi.encodeCall(IERC7575.previewRedeem, (held)));
        // Bounded to what `available` and a draw hold, so a neighbour quoting the maximum cannot overflow their sum.
        capacity = valued ? MathLib.min(MathLib.min(instant, backing), type(uint128).max) : 0;
    }

    /// @dev A one-word view of another pool's contract, whose revert (a paused or stale oracle) or running out of
    ///      `QUOTE_GAS` reads as no answer rather than failing the caller. Only the first word of the answer is
    ///      copied, so a target returning kilobytes cannot make the caller pay for the memory.
    function _read(address target, bytes memory data) internal view returns (bool ok, uint256 value) {
        uint256 quoteGas = QUOTE_GAS;
        bool success;
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            let out := mload(0x40)
            success := staticcall(quoteGas, target, add(data, 0x20), mload(data), out, 0x20)
            size := returndatasize()
            word := mload(out)
        }
        ok = success && size >= 32;
        value = ok ? word : 0;
    }

    /// @dev From the registry, not the caller-chosen vault: an unknown address maps to no pool.
    function _details(address vault) internal view returns (VaultDetails memory) {
        return spokeRegistry.vaultDetails(vault);
    }
}
