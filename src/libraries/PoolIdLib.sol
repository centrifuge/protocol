// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";

library PoolIdLib {
    function chainId(PoolId poolId) internal pure returns (uint32) {
        return uint32(PoolId.unwrap(poolId) >> 32);
    }
}
