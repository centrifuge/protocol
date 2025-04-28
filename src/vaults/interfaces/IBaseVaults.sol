// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {IERC7575, IERC165} from "src/misc/interfaces/IERC7575.sol";
import {
    IERC7540Operator,
    IERC7714,
    IERC7741,
    IERC7540Redeem,
    IERC7887Redeem,
    IERC7887Deposit,
    IERC7540Deposit
} from "src/misc/interfaces/IERC7540.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IBaseInvestmentManager} from "src/vaults/interfaces/investments/IBaseInvestmentManager.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";

/// @notice Interface for the all vault contracts
/// @dev Must be implemented by all vaults
interface IBaseVault is IERC7540Operator, IERC7741, IERC7714, IERC7575, IRecoverable {
    error FileUnrecognizedParam();
    error NotEndorsed();
    error CannotSetSelfAsOperator();
    error ExpiredAuthorization();
    error AlreadyUsedAuthorization();
    error InvalidAuthorization();
    error InvalidController();
    error InsufficientBalance();
    error RequestRedeemFailed();
    error TransferFromFailed();

    event File(bytes32 indexed what, address data);

    /// @notice Identifier of the Centrifuge pool
    function poolId() external view returns (PoolId);

    /// @notice Identifier of the share class of the Centrifuge pool
    function scId() external view returns (ShareClassId);

    /// @notice Set msg.sender as operator of owner, to `approved` status
    /// @dev    MUST be called by endorsed sender
    function setEndorsedOperator(address owner, bool approved) external;

    /// @notice Returns the base investment manager contract handling the vault.
    /// @dev This naming MUST NOT change due to requirements of legacy vaults (v2)
    /// @return IBaseInvestmentManager The address of the manager contract that is between vault and gateway
    function manager() external view returns (IBaseInvestmentManager);
}

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
