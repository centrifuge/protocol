// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseVault} from "./IBaseVault.sol";
import {IAsyncVault} from "./IAsyncVault.sol";

import {IMulticall} from "../../misc/interfaces/IMulticall.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {BaseSyncDepositVault} from "../BaseVaults.sol";

interface IVaultRouter is IMulticall {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event LockDepositRequest(
        IBaseVault indexed vault, address indexed controller, address indexed owner, address sender, uint256 amount
    );
    event UnlockDepositRequest(IBaseVault indexed vault, address indexed controller, address indexed receiver);
    event ExecuteLockedDepositRequest(IBaseVault indexed vault, address indexed controller, address sender);

    error InvalidOwner();
    error NoLockedBalance();
    error NoLockedRequest();
    error ZeroBalance();
    error InvalidSender();
    error NonSyncDepositVault();
    error NonAsyncVault();

    //----------------------------------------------------------------------------------------------
    // Manage permissionless claiming
    //----------------------------------------------------------------------------------------------

    /// @notice Enable permissionless claiming
    /// @dev    After this is called, anyone can claim tokens to msg.sender.
    ///         Even any requests submitted directly to the vault (not through the VaultRouter) will be
    ///         permissionlessly claimable through the VaultRouter, until `disable()` is called.
    function enable(IBaseVault vault) external payable;

    /// @notice Disable permissionless claiming
    function disable(IBaseVault vault) external payable;

    //----------------------------------------------------------------------------------------------
    // Deposit
    //----------------------------------------------------------------------------------------------

    /// @notice Check `IERC7540Deposit.requestDeposit`.
    /// @param  vault The vault to deposit into
    /// @param  amount Check @param IERC7540Deposit.requestDeposit.assets
    /// @param  controller Check @param IERC7540Deposit.requestDeposit.controller
    /// @param  owner Check @param IERC7540Deposit.requestDeposit.owner
    function requestDeposit(IAsyncVault vault, uint256 amount, address controller, address owner) external payable;

    /// @notice Check `IERC4626.deposit`.
    /// @param  vault The vault to deposit into
    /// @param  assets Check @param IERC4626.deposit.assets
    /// @param  receiver Check @param IERC4626.deposit.receiver
    /// @param  owner User from which to transfer the assets, either msg.sender or the VaultRouter
    function deposit(BaseSyncDepositVault vault, uint256 assets, address receiver, address owner) external payable;

    /// @notice Check IERC7540Deposit.mint
    /// @param  vault Address of the vault
    /// @param  receiver Check IERC7540Deposit.mint.receiver
    /// @param  controller Check IERC7540Deposit.mint.owner
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable;

    /// @notice Check `IERC7887Deposit.cancelDepositRequest`.
    /// @param  vault The vault where the deposit was initiated
    function cancelDepositRequest(IAsyncVault vault) external payable;

    /// @notice Check IERC7887Deposit.claimCancelDepositRequest
    ///
    /// @param  vault Address of the vault
    /// @param  receiver Check  IERC7887Deposit.claimCancelDepositRequest.receiver
    /// @param  controller Check  IERC7887Deposit.claimCancelDepositRequest.controller
    function claimCancelDepositRequest(IAsyncVault vault, address receiver, address controller) external payable;

    //----------------------------------------------------------------------------------------------
    // Redeem
    //----------------------------------------------------------------------------------------------

    /// @notice Check `IERC7540Redeem.requestRedeem`.
    /// @param  vault The vault to deposit into
    /// @param  amount Check @param IERC7540Redeem.requestRedeem.shares
    /// @param  controller Check @param IERC7540Redeem.requestRedeem.controller
    /// @param  owner Check @param IERC7540Redeem.requestRedeem.owner
    function requestRedeem(IAsyncVault vault, uint256 amount, address controller, address owner) external payable;

    /// @notice Check IERC7575.withdraw
    /// @dev    If the underlying vault asset is a wrapped one,
    ///         `VaultRouter.unwrap` is called and the unwrapped
    ///         asset is sent to the receiver
    /// @param  vault Address of the vault
    /// @param  receiver Check IERC7575.withdraw.receiver
    /// @param  controller Check IERC7575.withdraw.owner
    function claimRedeem(IBaseVault vault, address receiver, address controller) external payable;

    /// @notice Check `IERC7887Redeem.cancelRedeemRequest`.
    /// @param  vault The vault where the deposit was initiated
    function cancelRedeemRequest(IAsyncVault vault) external payable;

    /// @notice Check IERC7887Redeem.claimableCancelRedeemRequest
    ///
    /// @param  vault Address of the vault
    /// @param  receiver Check  IERC7887Redeem.claimCancelRedeemRequest.receiver
    /// @param  controller Check  IERC7887Redeem.claimCancelRedeemRequest.controller
    function claimCancelRedeemRequest(IAsyncVault vault, address receiver, address controller) external payable;

    //----------------------------------------------------------------------------------------------
    // Cross-chain transfers
    //----------------------------------------------------------------------------------------------

    /// @notice Intended to be used in a batch with `deposit` or `claimDeposit`.
    ///         The preceding vault call's `receiver` must be set to `address(this)` (the router),
    ///         not this function's `receiver` parameter (which is the destination bytes32 address on the
    ///         remote chain). `owner` must be either `msg.sender` or `address(this)` (the router itself,
    ///         for the batched case where the router holds the shares as an intermediate step).
    function crosschainTransferShares(
        BaseSyncDepositVault vault,
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
    // View Methods
    //----------------------------------------------------------------------------------------------

    /// @notice Check ISpoke.getVault
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address);

    /// @notice Called to check if `user` has permissions on `vault` to execute requests
    ///
    /// @param vault Address of the `vault` the `user` wants to operate on
    /// @param user Address of the `user` that will operates on the `vault`
    /// @return Whether `user` has permissions to operate on `vault`
    function hasPermissions(IBaseVault vault, address user) external view returns (bool);

    /// @notice Returns whether the controller has called `enable()` for the given `vault`
    function isEnabled(IBaseVault vault, address controller) external view returns (bool);

    /// @notice Spoke-side entry point for this chain's pool and share class operations
    function spoke() external view returns (ISpoke);

    /// @notice Stores pool, share class, asset, price and vault state for the spoke side
    function spokeRegistry() external view returns (ISpokeRegistry);
}
