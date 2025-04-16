// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {PoolId} from "src/common/types/PoolId.sol";

interface ISharedDependency {
    /// @notice Emitted when a call to `file()` was performed.
    event File(address dependency);

    /// @notice Updates the dependency parameter.
    function file(address dependency) external;

    /// @notice perform the payment associated to a Pool
    function dependency() external returns (address);
}
