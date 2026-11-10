// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRequestPolicy} from "./IVaultPlugins.sol";

/// @notice One bucket per controller per side, unbatched, so the vault folds it as it settles and claimable events
///         fire at fulfillment. The key is the controller, so the vault's `bucketOf(key, isDeposit)` finds the bucket.
interface IPerInvestorPolicy is IRequestPolicy {}

/// @notice A fresh bucket per request, unbatched, so the vault folds it as it settles and claimable events fire at
///         fulfillment.
interface IPerRequestPolicy is IRequestPolicy {
    event PerRequestConfigured(bool transfersEnabled);
}

/// @notice One shared bucket per side per time window, flushed once the window closes.
/// @dev    `isClosed` is true only once the bucket's window has fully elapsed. The policy allows every transfer;
///         on a vault with an instant lane the vault still requires the caller to act for the recipient or the
///         sender to be a sponsor.
interface IPerPeriodPolicy is IRequestPolicy {
    event PerPeriodConfigured(uint64 window, uint64 offset, uint64 depositNotice, uint64 redeemNotice);

    /// @notice The offset is not below the window length.
    error InvalidOffset();

    /// @notice Window length in seconds. Fixed at construction, so different cutoffs are separate
    ///         instances.
    function window() external view returns (uint64);

    /// @notice Phase of the window boundary, in seconds: a daily window closing at 14:00 UTC is
    ///         `window = 1 days`, `offset = 14 hours`. Strictly below `window`.
    function offset() external view returns (uint64);

    /// @notice Seconds a deposit waits: a request made at `t` joins the window that holds `t + depositNotice`.
    ///         Under one window it is a cutoff before each close. Zero joins the open window.
    function depositNotice() external view returns (uint64);

    /// @notice The same for redeem requests.
    function redeemNotice() external view returns (uint64);
}
