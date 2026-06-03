// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {FlowRegression} from "./FlowRegression.sol";

import {stdJson} from "forge-std/StdJson.sol";

/// @title  FlowRegressionTest
/// @notice Unit test for `FlowRegression._parseBytes16`. The production helper
///         uses a loop (the assembly `mload` variant participated in a
///         legacy-codegen stack-too-deep hunt), so this fuzz test pins the loop
///         variant to (a) a JSON round-trip and (b) byte-for-byte equivalence
///         with the original assembly implementation. No fork required.
contract FlowRegressionTest is FlowRegression {
    using stdJson for string;

    /// @dev The original assembly implementation, kept here as the reference.
    function _parseBytes16Assembly(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        assembly {
            result := mload(add(rawBytes, 32))
        }
    }

    function _tokenIdJson(bytes16 value) internal pure returns (string memory) {
        return string.concat("{\"tokenId\": \"", vm.toString(abi.encodePacked(value)), "\"}");
    }

    function testFuzz_parseBytes16RoundTrip(bytes16 value) public pure {
        assertEq(_parseBytes16(_tokenIdJson(value), ".tokenId"), value);
    }

    function testFuzz_parseBytes16MatchesAssemblyVariant(bytes16 value) public pure {
        string memory json = _tokenIdJson(value);
        assertEq(_parseBytes16(json, ".tokenId"), _parseBytes16Assembly(json, ".tokenId"));
    }

    function test_parseBytes16RevertsOnWrongLength() public {
        string memory json = string.concat("{\"tokenId\": \"", vm.toString(abi.encodePacked(bytes32(0))), "\"}");
        vm.expectRevert(bytes("Expected 16 bytes for tokenId"));
        this.exposed_parseBytes16(json, ".tokenId");
    }

    /// @dev External wrapper so `vm.expectRevert` applies to a call, not a jump.
    function exposed_parseBytes16(string memory json, string memory path) external pure returns (bytes16) {
        return _parseBytes16(json, path);
    }
}
