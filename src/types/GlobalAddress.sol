// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

type GlobalAddress is uint256;

function addr(GlobalAddress addr_) pure returns (address) {
    return address(uint160(GlobalAddress.unwrap(addr_)));
}

function chainId(GlobalAddress addr_) pure returns (uint32) {
    return uint32(GlobalAddress.unwrap(addr_) >> 20);
}

function isNull(GlobalAddress addr_) pure returns (bool) {
    return GlobalAddress.unwrap(addr_) == 0;
}

using {addr, chainId, isNull} for GlobalAddress global;
