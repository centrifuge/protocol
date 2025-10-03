// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IUpdateContract {
    error UnknownUpdateContractType();

    /// @notice Triggers an update on the target contract.
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  payload The payload to be processed by the target address
    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) external;
}
