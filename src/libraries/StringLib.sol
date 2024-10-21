// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

library StringLib {
    bytes32 constant EMPTY_STRING = keccak256(abi.encodePacked(""));

    function isEmpty(string memory value) internal pure returns (bool) {
        return keccak256(abi.encodePacked(value)) == EMPTY_STRING;
    }

    function toString(uint256 value) internal pure returns (string memory) {
        unchecked {
            if (value == 0) {
                return "0";
            }
            uint256 j = value;
            uint256 len;
            while (j != 0) {
                len++;
                j /= 10;
            }
            bytes memory bstr = new bytes(len);
            uint256 k = len;
            while (value != 0) {
                k = k - 1;
                uint8 temp = (48 + uint8(value - value / 10 * 10));
                bytes1 b1 = bytes1(temp);
                bstr[k] = b1;
                value /= 10;
            }
            return string(bstr);
        }
    }
}
