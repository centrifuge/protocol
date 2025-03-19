// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {DelegationToken} from "src/cfg/DelegationToken.sol";

/// @title  Centrifuge Token
contract CFG is DelegationToken {
    constructor() DelegationToken(18) {
        file("name", "Centrifuge");
        file("symbol", "CFG");
    }
}
