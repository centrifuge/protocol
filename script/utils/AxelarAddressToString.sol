// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

// From https://github.com/axelarnetwork/axelar-gmp-sdk-solidity/blob/main/contracts/libs/AddressString.sol#L30C26-L45C6
library AxelarAddressToString {
    function toAxelarString(address address_) internal pure returns (string memory) {
        bytes memory addressBytes = abi.encodePacked(address_);
        bytes memory characters = "0123456789abcdef";
        bytes memory stringBytes = new bytes(42);

        stringBytes[0] = "0";
        stringBytes[1] = "x";

        for (uint256 i; i < 20; ++i) {
            stringBytes[2 + i * 2] = characters[uint8(addressBytes[i] >> 4)];
            stringBytes[3 + i * 2] = characters[uint8(addressBytes[i] & 0x0f)];
        }

        return string(stringBytes);
    }
}
