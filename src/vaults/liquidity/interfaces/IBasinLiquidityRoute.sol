// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

import {ILiquidityRoute} from "../../policies/interfaces/IVaultPlugins.sol";

/// @notice The subset of a Grove Basin this route calls.
interface IGroveBasinLike {
    function withdraw(address asset, address receiver, uint256 maxAssetsToWithdraw)
        external
        returns (uint256 assetsWithdrawn);
    function previewWithdraw(address asset, uint256 maxAssetsToWithdraw)
        external
        view
        returns (uint256 sharesToBurn, uint256 assetsWithdrawn);
    function liquidityProvider() external view returns (address);
}

/// @notice A vault's credit line with the venue, in two slots: the two limits together, then what is owed.
struct CreditLine {
    uint128 limit;
    uint128 credit;
    uint128 receivable;
}

/// @notice Liquidity route drawing on a Grove Basin, under a credit line both the pool and the basin's
///         liquidity provider agree to. Every draw deposits as many liability accounting tokens
///         (`AccountingToken`, id `toTokenId(pool, asset, true)`) into the vault's share class in the
///         pool's escrow, and every repayment withdraws and burns them, so the debt moves the pool's
///         balance sheet in the same transaction as the cash. The route must be a spoke manager and an
///         accounting token minter of each drawing pool, and that liability token a registered spoke
///         asset; without them `available` is zero and draws revert.
interface IBasinLiquidityRoute is ILiquidityRoute, IManagerCallFromHub, IRecoverable {
    event SetLimit(PoolId indexed poolId, address indexed vault, uint128 limit);
    event SetCredit(PoolId indexed poolId, address indexed vault, uint128 credit);
    event BasinProvided(PoolId indexed poolId, address indexed vault, uint128 assets);
    event BasinRepaid(PoolId indexed poolId, address indexed vault, address indexed from, uint128 assets);
    event BasinLiabilityLeftBooked(PoolId indexed poolId, address indexed vault, uint128 assets);

    /// @notice Only the vault itself may draw on its line.
    error NotVault();

    /// @notice Only the Envoy may set a vault's limit.
    error NotEnvoy();

    /// @notice The vault is not one of the configuring pool's vaults.
    error WrongPool();

    /// @notice The caller is not a spoke manager of the vault's pool.
    error NotManager();

    /// @notice The draw exceeds the vault's remaining line.
    error ExceedsLimit();

    /// @notice Setting a limit takes no native value.
    error UnexpectedValue();

    /// @notice Only the basin's liquidity provider may set a vault's credit.
    error NotLiquidityProvider();

    /// @notice The basin delivered less than the draw asked for.
    error InsufficientLiquidity();

    /// @notice Sets the credit the basin's liquidity provider extends to a vault: the most the vault
    ///         may have drawn and not yet repaid. Zero withdraws it. Callable by the liquidity provider
    ///         only, so the venue consents to every pool that draws on it.
    function setCredit(address vault, uint128 credit) external;

    /// @notice Repays drawn liquidity to the basin's liquidity provider, reducing the vault's
    ///         receivable and withdrawing the matching liability from the pool's escrow. The payer is
    ///         the caller, which must be a spoke manager of the vault's pool. What the route
    ///         cannot withdraw (its manager or minter role revoked, or the escrow's liability balance
    ///         short) stays booked and is reported by `BasinLiabilityLeftBooked`; the repayment still lands.
    function repay(address vault, uint128 assets) external;

    /// @notice The most a vault's pool lets it owe the venue. Set through the Envoy (`fromHub`, payload
    ///         `abi.encode(address vault, uint128 limit)`); zero disables the vault.
    function limit(address vault) external view returns (uint128);

    /// @notice The most the venue lets a vault owe it, set by the liquidity provider.
    function credit(address vault) external view returns (uint128);

    /// @notice Drawn and not yet repaid.
    function receivable(address vault) external view returns (uint128);

    /// @notice The venue's liquidity bounded by the vault's remaining line; not a reservation.
    /// @dev    A venue whose quote reverts or answers short reads as no liquidity, and so does a pool the draw's debt
    ///         could not be booked in.
    function available(address vault) external view override returns (uint128 assets);
}
