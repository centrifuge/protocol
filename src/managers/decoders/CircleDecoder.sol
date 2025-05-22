// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseDecoder} from "src/managers/decoders/BaseDecoder.sol";

contract CircleDecoder is BaseDecoder {
    // @desc Deposit assets into Circle to burn, in order to bridge to another chain
    // @tag destinationDomain:uint32:the id of the destination chain
    // @tag mintRecipient:bytes32:the address of the recipient on the destination chain in a bytes32 format
    // @tag burnToken:address:the address of the token to burn
    function depositForBurn(uint256, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(destinationDomain, mintRecipient, burnToken);
    }

    // @desc Receive a message from Circle, in order to mint tokens on the destination chain
    function receiveMessage(bytes memory, bytes memory) external pure returns (bytes memory addressesFound) {
        // nothing to sanitize
        return addressesFound;
    }
}
