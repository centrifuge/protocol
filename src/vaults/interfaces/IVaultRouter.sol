// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAsyncVault} from "./IAsyncVault.sol";

import {IMulticall} from "../../misc/interfaces/IMulticall.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

/// @notice Investor-facing multicall entrypoint for vaults: approvals, requests, claims and cross-chain share
///         transfers batched in one transaction. It holds no state of its own beyond the vault it resolves.
interface IVaultRouter is IMulticall {
    error InvalidOwner();
    error InvalidSender();
    error InvalidController();
    error ValueAlreadySpent();

    //----------------------------------------------------------------------------------------------
    // Deposit
    //----------------------------------------------------------------------------------------------

    /// @notice Check `IERC7540Deposit.requestDeposit`. `owner` is the caller, which must have enabled the
    ///         router, or the router itself, holding the assets from an earlier call in the batch. On a vault with
    ///         both lanes, the router funding the request (`owner` is the router) also needs the caller to have made
    ///         the router their operator on that vault, since the vault sees an owner that is not the controller.
    ///         `controller` must be the caller: the router is an
    ///         investor's operator, so a request it relayed for someone else would count as theirs.
    function requestDeposit(IAsyncVault vault, uint256 amount, address controller, address owner) external payable;

    /// @notice An instant deposit (`IERC7575.deposit`), from the caller or from assets the router holds. The vault
    ///         sees the router as the depositor, so the router checks the caller against the share token's hook, as a
    ///         direct deposit would be, and reverts with `InvalidSender` where the hook refuses it.
    /// @param  owner User from which to transfer the assets, either msg.sender or the VaultRouter
    function deposit(IAsyncVault vault, uint256 assets, address receiver, address owner) external payable;

    /// @notice Claims all of `controller`'s claimable shares to `receiver`.
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable;

    //----------------------------------------------------------------------------------------------
    // Redeem
    //----------------------------------------------------------------------------------------------

    /// @notice Check `IERC7540Redeem.requestRedeem`, with `owner` and `controller` as for `requestDeposit`.
    function requestRedeem(IAsyncVault vault, uint256 amount, address controller, address owner) external payable;

    /// @notice Claims all of `controller`'s claimable assets to `receiver`.
    function claimRedeem(IAsyncVault vault, address receiver, address controller) external payable;

    //----------------------------------------------------------------------------------------------
    // Cross-chain transfers
    //----------------------------------------------------------------------------------------------

    /// @notice Intended to be used in a batch with `deposit` or `claimDeposit`. In a multicall the value sent funds
    ///         one transfer: a second transfer that forwards value reverts `ValueAlreadySpent`, since every call of a
    ///         batch sees the same `msg.value` and would otherwise spend what others left in the router.
    ///         The preceding vault call's `receiver` must be set to `address(this)` (the router),
    ///         not this function's `receiver` parameter (which is the destination bytes32 address on the
    ///         remote chain). `owner` must be either `msg.sender` or `address(this)` (the router itself,
    ///         for the batched case where the router holds the shares as an intermediate step).
    function crosschainTransferShares(
        IAsyncVault vault,
        uint128 shares,
        uint16 centrifugeId,
        bytes32 receiver,
        address owner,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable;

    //----------------------------------------------------------------------------------------------
    // ERC20 permit
    //----------------------------------------------------------------------------------------------

    /// @notice Check IERC20.permit
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The linked vault of a share class for `asset`, or zero when there is none.
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address);

    /// @notice Returns whether the controller has made the router its operator on `vault` (`vault.setOperator`),
    ///         which lets anyone claim the controller's settled requests to the controller through the router.
    function isEnabled(IAsyncVault vault, address controller) external view returns (bool);

    /// @notice Spoke-side entry point for this chain's pool and share class operations
    function spoke() external view returns (ISpoke);

    /// @notice Stores pool, share class, asset, price and vault state for the spoke side
    function spokeRegistry() external view returns (ISpokeRegistry);
}
