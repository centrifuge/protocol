// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "src/libraries/MathLib.sol";

/// @title  CastLib
library CastLib {
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

    function stringToBytes128(string memory str) internal pure returns (bytes memory) {
        bytes memory bytes128 = new bytes(128);

        uint32 length = uint32(MathLib.min(128, bytes(str).length));

        for (uint256 i; i < length && bytes(str)[i] != 0; i++) {
            bytes128[i] = bytes(str)[i];
        }

        return bytes128;
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
