// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";

import {MathLib} from "src/libraries/MathLib.sol";

library PoolIdLib {
    using MathLib for uint256;

    function chainId(PoolId poolId) internal pure returns (uint32) {
        return uint32(PoolId.unwrap(poolId) >> 32);
    }

    function newFrom(uint32 localPoolId) internal view returns (PoolId) {
        return PoolId.wrap((uint64(block.chainid.toUint32()) << 32) | uint64(localPoolId));
    }
}
