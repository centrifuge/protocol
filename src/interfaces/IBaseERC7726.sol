// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/types/D18.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

/// Provides a base implementation for all ERC7726 valuation in the system
interface IBaseERC7726 is IERC7726 {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'assetManager' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
