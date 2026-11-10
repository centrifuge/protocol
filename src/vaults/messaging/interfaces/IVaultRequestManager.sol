// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  IVaultRequestManager
/// @notice The typed surface a vault sees of its request manager: requests go out through
///         {sendDepositRequest}/{sendRedeemRequest} and settlements come back through the
///         {IVaultDepositCallbacks}/{IVaultRedeemCallbacks} functions the vault implements. The
///         manager owns the messaging scheme, so the vault knows no message formats.
interface IVaultRequestManager {
    /// @notice Forwards a flushed deposit request for the calling vault's position.
    /// @dev    The manager resolves the position from the calling vault and derives the hub-visible
    ///         request id from the caller and `localId`, so a vault cannot emit a sibling's id.
    function sendDepositRequest(uint96 localId, uint128 amount) external;

    /// @notice Forwards a flushed redeem request for the calling vault's position.
    function sendRedeemRequest(uint96 localId, uint128 amount) external;
}

/// @notice Deposit-side settlement callbacks, applied by the pool's registered request manager.
/// @dev    Amount-only: the vault prices claims from the settled amounts.
interface IVaultDepositCallbacks {
    /// @notice The hub approved `assetAmount` of pending deposits: the request-time reservation is
    ///         released so the assets enter the hub-accounted holding.
    function approveDeposits(uint96 localId, uint128 assetAmount) external;

    /// @notice The hub issued `shareAmount` new shares to the escrow, pending their claim.
    function issueShares(uint96 localId, uint128 shareAmount) external;

    /// @notice Settles a deposit bucket: `assetAmount` was consumed for `shareAmount` claimable shares.
    /// @dev    A manager MUST NOT settle shares against a zero `assetAmount`: the blended price would be
    ///         zero, leaving `maxMint` non-zero while `maxDeposit` reads nothing. Not checked here.
    function fulfillDepositRequest(uint96 localId, uint128 assetAmount, uint128 shareAmount) external;

    /// @notice Cancels part of a deposit order: `grossAssetAmount` (gross) retires the pending
    ///         request and releases the request-time reservation, `netAssetAmount` is what the
    ///         investor may claim, and the difference is a retained cancellation fee. A net above
    ///         the gross is refused.
    function cancelDeposit(uint96 localId, uint128 grossAssetAmount, uint128 netAssetAmount) external;
}

/// @notice Redeem-side settlement callbacks, applied by the pool's registered request manager.
interface IVaultRedeemCallbacks {
    /// @notice The hub revoked `shareAmount` escrowed shares against an `assetAmount` payout: the
    ///         vault burns the shares and reserves the payout atomically.
    function revokeShares(uint96 localId, uint128 assetAmount, uint128 shareAmount) external;

    /// @notice Settles a redeem bucket: `shareAmount` was consumed for `assetAmount` claimable assets.
    function fulfillRedeemRequest(uint96 localId, uint128 assetAmount, uint128 shareAmount) external;

    /// @notice Share-denominated twin of {IVaultDepositCallbacks.cancelDeposit}.
    function cancelRedeem(uint96 localId, uint128 grossShareAmount, uint128 netShareAmount) external;
}
