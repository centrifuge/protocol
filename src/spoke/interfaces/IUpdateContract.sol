// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

interface IUpdateContract {
    error UnknownUpdateContractType();

    /// @notice Triggers an update on the target contract.
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  payload The payload to be processed by the target address
    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) external;
}
