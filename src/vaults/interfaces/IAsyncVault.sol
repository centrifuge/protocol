// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseVault} from "./IBaseVault.sol";
import {IAsyncRedeemManager} from "./IVaultManagers.sol";

import {IERC7540Redeem, IERC7887Redeem, IERC7887Deposit, IERC7540Deposit} from "../../misc/interfaces/IERC7540.sol";

/**
 * @title  IAsyncRedeemVault
 * @dev    This is the specific set of interfaces used by the Centrifuge implementation of ERC7540,
 *         as a fully asynchronous Vault, with cancellation support, and authorize operator signature support.
 */
interface IAsyncRedeemVault is IERC7540Redeem, IERC7887Redeem, IBaseVault {
    event RedeemClaimable(address indexed controller, uint256 indexed requestId, uint256 assets, uint256 shares);
    event CancelRedeemClaimable(address indexed controller, uint256 indexed requestId, uint256 shares);

    /// @notice Callback invoked when a redeem request is triggered externally
    /// @param controller The address controlling the request
    /// @param owner The address that owns the shares
    /// @param shares The amount of shares to redeem
    function onRedeemRequest(address controller, address owner, uint256 shares) external;

    /// @notice Callback invoked when a redeem request becomes claimable
    /// @param owner The address that can claim the assets
    /// @param assets The amount of assets available to claim
    /// @param shares The amount of shares that were redeemed
    function onRedeemClaimable(address owner, uint256 assets, uint256 shares) external;

    /// @notice Callback invoked when a cancelled redeem request becomes claimable
    /// @param owner The address that can claim the returned shares
    /// @param shares The amount of shares being returned
    function onCancelRedeemClaimable(address owner, uint256 shares) external;

    /// @notice Get the asynchronous redeem manager for this vault
    /// @return The async redeem manager contract
    function asyncRedeemManager() external view returns (IAsyncRedeemManager);
}

interface IAsyncVault is IERC7540Deposit, IERC7887Deposit, IAsyncRedeemVault {
    event DepositClaimable(address indexed controller, uint256 indexed requestId, uint256 assets, uint256 shares);
    event CancelDepositClaimable(address indexed controller, uint256 indexed requestId, uint256 assets);

    error InvalidOwner();
    error RequestDepositFailed();

    /// @notice Callback invoked when a deposit request becomes claimable
    /// @param owner The address that can claim the shares
    /// @param assets The amount of assets that were deposited
    /// @param shares The amount of shares available to claim
    function onDepositClaimable(address owner, uint256 assets, uint256 shares) external;

    /// @notice Callback invoked when a cancelled deposit request becomes claimable
    /// @param owner The address that can claim the returned assets
    /// @param assets The amount of assets being returned
    function onCancelDepositClaimable(address owner, uint256 assets) external;
}
