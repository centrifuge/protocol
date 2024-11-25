// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

library StringLib {
    function isEmpty(string memory value) internal pure returns (bool) {
        return bytes(value).length == 0;
    }
}
