// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC7575} from "../../misc/interfaces/IERC7575.sol";
import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";
import {IERC7540Operator, IERC7714, IERC7741} from "../../misc/interfaces/IERC7540.sol";

import {IVault} from "../../spoke/interfaces/IVault.sol";

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
}
