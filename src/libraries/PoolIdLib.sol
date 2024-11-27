// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";

library PoolIdLib {
    function chainId(PoolId poolId) internal pure returns (uint64) {
        return uint64(PoolId.unwrap(poolId) >> 32);
    }
}
