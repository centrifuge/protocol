// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  CastLib
library CastLib {
    function toAddressLeftPadded(bytes32 addr) internal pure returns (address) {
        require(bytes12(addr) == 0, "First 12 bytes should be zero");
        return address(uint160(uint256(addr)));
    }

    function toBytes32LeftPadded(address addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    function toAddress(string calldata addr) internal pure returns (address) {
        require(bytes(addr).length == 20, "Input should be 20 bytes");
        return address(bytes20(bytes(addr)));
    }

    function toAddress(bytes32 addr) internal pure returns (address) {
        require(uint96(uint256(addr)) == 0, "Input should be 20 bytes");
        return address(bytes20(addr));
    }

    function toString(address addr) internal pure returns (string memory) {
        return string(abi.encodePacked(addr));
    }

    function toBytes32(address addr) internal pure returns (bytes32) {
        return bytes32(bytes20(addr));
    }

    /// @dev Adds zero padding
    function toBytes32(string memory source) internal pure returns (bytes32) {
        return bytes32(bytes(source));
    }

    /// @dev Removes zero padding
    function bytes128ToString(bytes memory _bytes128) internal pure returns (string memory) {
        require(_bytes128.length == 128, "Input should be 128 bytes");

        uint8 i = 0;
        while (i < 128 && _bytes128[i] != 0) {
            i++;
        }

        bytes memory bytesArray = new bytes(i);

        for (uint8 j; j < i; j++) {
            bytesArray[j] = _bytes128[j];
        }

        return string(bytesArray);
    }

    function toString(bytes32 _bytes32) internal pure returns (string memory) {
        uint8 i = 0;
        while (i < 32 && _bytes32[i] != 0) {
            i++;
        }
        bytes memory bytesArray = new bytes(i);
        for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
            bytesArray[i] = _bytes32[i];
        }
        return string(bytesArray);
    }
}
