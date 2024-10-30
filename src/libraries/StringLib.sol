// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

library StringLib {
    bytes32 constant EMPTY_STRING = keccak256(abi.encodePacked(""));

    function isEmpty(string memory value) internal pure returns (bool) {
        return keccak256(abi.encodePacked(value)) == EMPTY_STRING;
    }
}
