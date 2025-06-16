// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IERC7540Operator, IERC7714, IERC7741} from "src/misc/interfaces/IERC7540.sol";
import {IERC7575} from "src/misc/interfaces/IERC7575.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IVault} from "src/spoke/interfaces/IVault.sol";

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

    /// @notice Identifier of the Centrifuge pool
    function poolId() external view returns (PoolId);

    /// @notice Identifier of the share class of the Centrifuge pool
    function scId() external view returns (ShareClassId);

    /// @notice Set msg.sender as operator of owner, to `approved` status
    /// @dev    MUST be called by endorsed sender
    function setEndorsedOperator(address owner, bool approved) external;
}
