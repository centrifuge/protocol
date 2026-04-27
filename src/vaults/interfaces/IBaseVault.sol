// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseRequestManager} from "./IBaseRequestManager.sol";

import {IERC7575} from "../../misc/interfaces/IERC7575.sol";
import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";
import {IERC7540Operator, IERC7714, IERC7741} from "../../misc/interfaces/IERC7540.sol";

import {IVault} from "../../core/spoke/interfaces/IVault.sol";

import {IRoot} from "../../admin/interfaces/IRoot.sol";

/// @notice Interface for the all vault contracts
/// @dev Must be implemented by all vaults
interface IBaseVault is IVault, IERC7540Operator, IERC7741, IERC7714, IERC7575, IRecoverable {
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

    /// @notice Set msg.sender as operator of owner, to `approved` status
    /// @dev    MUST be called by endorsed sender
    function setEndorsedOperator(address owner, bool approved) external;

    /// @notice Root authority that manages ward permissions and timelocked upgrades
    function root() external view returns (IRoot);

    /// @notice Request manager handling common deposit/redeem state (shared across vault types)
    function baseManager() external view returns (IBaseRequestManager);

    /// @notice EVM chain ID captured at construction, used for EIP-712 domain separator replay protection
    function deploymentChainId() external view returns (uint256);

    /// @notice keccak256 hash of the EIP-712 structured data type, needed for off-chain signature construction
    function AUTHORIZE_OPERATOR_TYPEHASH() external view returns (bytes32);

    /// @notice Price of 1 unit of share, quoted in the decimals of the asset
    function pricePerShare() external view returns (uint256);

    /// @notice Returns timestamp of the last share price update
    function priceLastUpdated() external view returns (uint64);
}
