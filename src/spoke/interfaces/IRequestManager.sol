// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

interface IRequestManager {
    error UnknownRequestType();

    /// @notice TODO
    function handleRequest(PoolId poolId, ShareClassId scId, bytes calldata payload) external;
}
