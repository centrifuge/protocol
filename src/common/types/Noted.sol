// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Meta} from "src/common/types/JournalEntry.sol";
import {D18, d18} from "src/misc/types/D18.sol";

struct Noted {
    uint128 amount;
    bytes32 encoded;
    bool asAllowance;
    Meta m;
}

/// @dev Easy way to construct a decimal number
function isRawPrice(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving price from bytes32
    return true;
}

function isValuation(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving price from bytes32
    return true;
}

function asRawPrice(Noted memory n) pure returns (D18) {
    // TODO: Fix retrieving price from bytes32
    return d18(1);
}

function asValuation(Noted memory n) pure returns (address) {
    // TODO: Fix retrieving valuation from bytes32
    return address(uint160(uint256(0)));
}

function allowance(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving allowance from bytes32
    return false;
}

using {asValuation, asRawPrice, isRawPrice, isValuation, allowance} for Noted global;
