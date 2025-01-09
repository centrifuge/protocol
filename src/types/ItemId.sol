// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

/// @notice Identify an Item stored in an array
type ItemId is uint32;

function newItemId(uint256 arrayLength) pure returns (ItemId) {
    // We reserve 0 for nullity checks, so internally item in position 0 carries a 1.
    return ItemId.wrap(MathLib.toUint32(arrayLength) + 1);
}

/// @notice Get the item position in the array
function index(ItemId itemId) pure returns (uint32) {
    // All items created thorugh `newItemId()` will never be 0
    return ItemId.unwrap(itemId) - 1;
}

function isNull(ItemId itemId) pure returns (bool) {
    return ItemId.unwrap(itemId) == 0;
}

using {index, isNull} for ItemId global;
