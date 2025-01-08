// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

type ItemId is uint32;

function newItemId(uint256 arrayLength) pure returns (ItemId) {
    return ItemId.wrap(MathLib.toUint32(arrayLength) + 1);
}

function index(ItemId itemId) pure returns (uint32) {
    return ItemId.unwrap(itemId) - 1;
}

function isNull(ItemId itemId) pure returns (bool) {
    return ItemId.unwrap(itemId) == 0;
}

using {index, isNull} for ItemId global;
