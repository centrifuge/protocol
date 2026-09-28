// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Chains, ChainConfig, LayerZeroConfig} from "../../../script/utils/ChainConfig.s.sol";

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
        '"opsAdmin":"0x0000000000000000000000000000000000000002",'
        '"namespace":"0x0000000000000000000000000000000000000003"}';

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

    // A lane-specific DVN set, keyed by a network name with a dash so the lookup path is exercised as written
    string constant DEFAULT_DVNS = '"requiredDVNs":["0x00000000000000000000000000000000000000A1"],'
        '"optionalDVNs":["0x00000000000000000000000000000000000000B1"],"optionalDVNThreshold":1';

    function _withOverride(string memory lane) private pure returns (string memory) {
        return _config(string.concat(DEFAULT_DVNS, ',"dvnOverrides":{"peer-b":{', lane, "}}"));
    }

    /// @dev The overridden lane gets its own set; every other lane keeps the default one
    function test_aLaneOverrideReplacesTheDefaultSetForThatLaneOnly() public view {
        string memory json = _withOverride(
            '"requiredDVNs":["0x00000000000000000000000000000000000000C1",'
            '"0x00000000000000000000000000000000000000C2"],'
            '"optionalDVNs":["0x00000000000000000000000000000000000000D1"],"optionalDVNThreshold":1'
        );
        ChainConfig memory config = this.parse(json);

        LayerZeroConfig memory lane = this.dvnsFor(config, json, "peer-b");
        assertEq(lane.requiredDVNs.length, 2, "override required set");
        assertEq(lane.requiredDVNs[0], address(0xC1));
        assertEq(lane.optionalDVNs[0], address(0xD1));
        assertEq(lane.layerZeroEid, 40001, "the rest of the adapter config is kept");

        LayerZeroConfig memory other = this.dvnsFor(config, json, "peer-c");
        assertEq(other.requiredDVNs.length, 1, "a lane with no override keeps the default");
        assertEq(other.requiredDVNs[0], address(0xA1));

        assertEq(config.adapters.layerZero.requiredDVNs[0], address(0xA1), "the default set is not mutated");
    }

    /// @dev An override is held to every rule the default set is
    function test_rejectsAnUnsortedOverride() public {
        vm.expectRevert(bytes("requiredDVNs must be sorted in ascending order"));
        this.parse(
            _withOverride(
                '"requiredDVNs":["0x00000000000000000000000000000000000000C2",'
                '"0x00000000000000000000000000000000000000C1"],"optionalDVNs":[],"optionalDVNThreshold":0'
            )
        );
    }

    /// @dev Without its required list an override would read as absent, and the lane silently fall back
    function test_rejectsAnOverrideWithoutRequiredDVNs() public {
        vm.expectRevert(bytes("dvnOverrides.peer-b must name requiredDVNs"));
        this.parse(_withOverride('"optionalDVNs":[],"optionalDVNThreshold":0'));
    }

    function dvnsFor(ChainConfig memory config, string memory json, string memory remote)
        external
        pure
        returns (LayerZeroConfig memory)
    {
        return config.dvnsFor(json, remote);
    }

    /// @dev An external hop, so that `vm.expectRevert` sees the revert at a lower depth than its own call
    function parse(string memory json) external pure returns (ChainConfig memory) {
        return Chains.parse(json, "somewhere");
    }
}
