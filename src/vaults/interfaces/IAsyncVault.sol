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

    /// @notice Callback when a redeem Request is triggered externally;
    function onRedeemRequest(address controller, address owner, uint256 shares) external;

    /// @notice Callback when a redeem Request becomes claimable
    function onRedeemClaimable(address owner, uint256 assets, uint256 shares) external;

    /// @notice Callback when a claim redeem Request becomes claimable
    function onCancelRedeemClaimable(address owner, uint256 shares) external;

    /// @notice Retrieve the asynchronous redeem manager
    function asyncRedeemManager() external view returns (IAsyncRedeemManager);
}

interface IAsyncVault is IERC7540Deposit, IERC7887Deposit, IAsyncRedeemVault {
    event DepositClaimable(address indexed controller, uint256 indexed requestId, uint256 assets, uint256 shares);
    event CancelDepositClaimable(address indexed controller, uint256 indexed requestId, uint256 assets);

    error InvalidOwner();
    error RequestDepositFailed();

    /// @notice Callback when a deposit Request becomes claimable
    function onDepositClaimable(address owner, uint256 assets, uint256 shares) external;

    /// @notice Callback when a claim deposit Request becomes claimable
    function onCancelDepositClaimable(address owner, uint256 assets) external;
}
