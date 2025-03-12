// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library Helpers {
    /**
     * @dev Converts an address to bytes32.
     * @param _addr The address to convert.
     * @return bytes32 bytes32 representation of the address.
     */
    function addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }
}
