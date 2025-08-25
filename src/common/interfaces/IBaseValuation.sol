// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "./IValuation.sol";

/// Provides a base implementation for all ERC7726 valuation in the system
interface IBaseValuation is IValuation {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedParam();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'assetRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;
}
