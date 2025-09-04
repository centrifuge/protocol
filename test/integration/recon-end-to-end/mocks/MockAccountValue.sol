// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

contract MockAccountValue {
    function valueFromInt(uint128 totalDebit, uint128 totalCredit) external pure returns (int128) {
        return int128(totalDebit) - int128(totalCredit);
    }

    function valueFromUint(uint128 totalDebit, uint128 totalCredit) external pure returns (uint128) {
        return totalDebit - totalCredit;
    }
}
