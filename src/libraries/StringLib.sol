// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

library StringLib {
    function isEmpty(string memory value) internal pure returns (bool) {
        return bytes(value).length == 0;
    }
}
