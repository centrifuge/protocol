// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Chains, ChainConfig} from "../../../script/utils/ChainConfig.s.sol";

import "forge-std/Test.sol";

/// @title  ChainConfigDvnParsingTest
/// @notice The rules a LayerZero DVN block must satisfy, each asserted against JSON written here — one case
///         per `require` in `_parseAdaptersConfig`, so every rule has a test that can actually reach it.
///
/// @dev    Hermetic on purpose. The earlier version of this file walked the configs on disk and re-asserted
///         what the parser had already required, so a violating config reverted inside the load before any
///         assertion ran: the walk could never fail through its own asserts, and on a branch holding only
///         well-formed fixtures it exercised nothing. Written-here JSON tests the rules themselves, speaks
///         on every branch regardless of what env/ holds, and covers the one rule the walk never touched —
///         that the required and optional lists share no DVN, the only adapter rule with a protocol
///         argument in its own comment.
///
///         Needs no fork: it reads and parses JSON only. The LayerZero metadata API
///         (https://metadata.layerzero-api.com/v1/metadata/dvns) is the off-chain source of truth for which
///         addresses are real DVNs; that cross-check belongs with the deployments that use them.
contract ChainConfigDvnParsingTest is Test {
    string constant NETWORK = '"network":{"chainId":424242,"environment":"testnet","centrifugeId":31,'
        '"protocolAdmin":"0x0000000000000000000000000000000000000001",'
        '"opsAdmin":"0x0000000000000000000000000000000000000002"}';

    string constant LZ_HEAD = '"adapters":{"layerZero":{"deploy":true,'
        '"endpoint":"0x00000000000000000000000000000000000000E1","layerZeroEid":40001,"blockConfirmations":1,';

    function _config(string memory dvns) private pure returns (string memory) {
        return string.concat("{", NETWORK, ",", LZ_HEAD, dvns, "}}}");
    }

    function test_parsesTheSplitDvnFields() public view {
        ChainConfig memory config = this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
                '"optionalDVNs":["0x00000000000000000000000000000000000000B1",'
                '"0x00000000000000000000000000000000000000B2"],"optionalDVNThreshold":1'
            )
        );

        assertEq(config.adapters.layerZero.requiredDVNs.length, 1);
        assertEq(config.adapters.layerZero.optionalDVNs.length, 2);
        assertEq(config.adapters.layerZero.optionalDVNThreshold, 1);
    }

    /// @dev The ULN requires both lists sorted ascending; a config in any other order is rejected on-chain
    ///      at the point where a message is already being sent, so the parser refuses it up front
    function test_rejectsUnsortedRequiredDVNs() public {
        vm.expectRevert(bytes("requiredDVNs must be sorted in ascending order"));
        this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A2",'
                '"0x00000000000000000000000000000000000000A1"],"optionalDVNs":[],"optionalDVNThreshold":0'
            )
        );
    }

    function test_rejectsUnsortedOptionalDVNs() public {
        vm.expectRevert(bytes("optionalDVNs must be sorted in ascending order"));
        this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
                '"optionalDVNs":["0x00000000000000000000000000000000000000B2",'
                '"0x00000000000000000000000000000000000000B1"],"optionalDVNThreshold":1'
            )
        );
    }

    /// @dev A DVN in both lists would count as a required attestation and a slot of the optional threshold
    function test_rejectsADvnInBothLists() public {
        vm.expectRevert(bytes("DVN appears in both required and optional lists"));
        this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
                '"optionalDVNs":["0x00000000000000000000000000000000000000A1"],"optionalDVNThreshold":1'
            )
        );
    }

    /// @dev Mirrors UlnBase: 0 < threshold <= optionalDVNs.length, and 0 when the list is empty
    function test_rejectsAThresholdAboveTheOptionalList() public {
        vm.expectRevert();
        this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
                '"optionalDVNs":["0x00000000000000000000000000000000000000B1"],"optionalDVNThreshold":2'
            )
        );
    }

    function test_rejectsAThresholdWithNoOptionalList() public {
        vm.expectRevert(bytes("optionalDVNThreshold must be 0 when no optional DVNs"));
        this.parse(
            _config(
                '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
                '"optionalDVNs":[],"optionalDVNThreshold":1'
            )
        );
    }

    function test_rejectsAConfigWithNoVerifierAtAll() public {
        vm.expectRevert(bytes("Must have at least one required DVN or a non-zero optional threshold"));
        this.parse(_config('"requiredDVNs":[],"optionalDVNs":[],"optionalDVNThreshold":0'));
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function parse(string memory json) external pure returns (ChainConfig memory) {
        return Chains.parse(json, "somewhere");
    }
}
