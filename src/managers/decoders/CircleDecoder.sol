// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {BaseDecoder} from "./BaseDecoder.sol";

contract CircleDecoder is BaseDecoder {
    /// @notice Deposit assets into Circle to burn, in order to bridge to another chain
    /// @param  destinationDomain the id of the destination chain
    /// @param  mintRecipient the address of the recipient on the destination chain in a bytes32 format
    /// @param  burnToken the address of the token to burn
    function depositForBurn(uint256, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        pure
        returns (bytes memory addressesFound)
    {
        addressesFound = abi.encodePacked(destinationDomain, mintRecipient, burnToken);
    }

    /// @notice Receive a message from Circle, in order to mint tokens on the destination chain
    function receiveMessage(bytes memory, bytes memory) external pure returns (bytes memory addressesFound) {
        // nothing to sanitize
        return addressesFound;
    }
}
