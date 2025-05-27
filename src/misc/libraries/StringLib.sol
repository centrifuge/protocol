// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

library StringLib {
    function isEmpty(string memory value) internal pure returns (bool) {
        return bytes(value).length == 0;
    }
}
