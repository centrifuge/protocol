// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainId} from "src/types/ChainId.sol";

type GlobalAddress is bytes32;

function addr(GlobalAddress addr_) pure returns (address) {
    return address(uint160(uint256(GlobalAddress.unwrap(addr_))));
}

function isNull(GlobalAddress addr_) pure returns (bool) {
    return GlobalAddress.unwrap(addr_) == 0;
}

using {addr, isNull} for GlobalAddress global;
