// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../misc/types/D18.sol";

/// @dev Price struct that contains a price and the timestamp at which it was computed.
struct Price {
    D18 price;
    uint64 computedAt;
}

/// @dev Checks if a price is valid. Prices do not expire in core; a price is valid once it has been
/// computed (computedAt != 0).
function isValid(Price memory price) pure returns (bool) {
    return price.computedAt != 0;
}

using {isValid} for Price global;
