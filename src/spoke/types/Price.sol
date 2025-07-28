// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

/// @dev Price struct that contains a price, the timestamp at which it was computed and the max age of the price.
struct Price {
    uint128 price;
    uint64 computedAt;
    uint64 maxAge;
}

/// @dev Checks if a price is valid. Returns false if computedAt is 0. Otherwise checks for block
/// timestamp <= computedAt + maxAge
function isValid(Price memory price) view returns (bool) {
    if (price.computedAt != 0) {
        return block.timestamp <= price.validUntil();
    } else {
        return false;
    }
}

/// @dev Computes the timestamp until the price is valid. Saturates at uint64.MAX.
function validUntil(Price memory price) pure returns (uint64) {
    unchecked {
        uint64 validUntil_ = price.computedAt + price.maxAge;
        if (validUntil_ < price.computedAt) {
            return type(uint64).max;
        }
        return validUntil_;
    }
}

/// @dev Retrieves the price as an D18 from the struct
function asPrice(Price memory price) pure returns (D18) {
    return d18(price.price);
}

using {isValid, asPrice, validUntil} for Price global;
