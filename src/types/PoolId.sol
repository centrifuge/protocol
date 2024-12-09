// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolIdLib} from "src/libraries/PoolIdLib.sol";

type PoolId is uint64;

using PoolIdLib for PoolId global;
