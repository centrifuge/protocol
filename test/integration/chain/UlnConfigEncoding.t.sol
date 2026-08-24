// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainConfigLib, LayerZeroConfig} from "../../../script/utils/ChainConfig.s.sol";

import "forge-std/Test.sol";

import {UlnConfig} from "../../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

/// @title  UlnConfigEncodingTest
/// @notice What `ChainConfigLib.encodeUlnConfig` hands to `endpoint.setConfig`, decoded back and checked.
///
/// @dev    These bytes used to be checked by LayerZero itself: `script/anvil/anvil.sh` forked Sepolia, so
///         the wiring ran against the real ULN, which rejects a config whose counts disagree with its
///         arrays or whose DVN lists are unsorted. The local chains stub the endpoint — it accepts
///         anything — so that check has to live here instead, or a malformed `UlnConfig` reaches a real
///         endpoint for the first time on a real chain.
///
///         Round-tripping is the whole method: `abi.decode` reads the same layout the ULN reads, so a
///         field that survives it is a field the endpoint will see the way this repo meant it.
contract UlnConfigEncodingTest is Test {
    address constant DVN_A = 0x00000000000000000000000000000000000000A1;
    address constant DVN_B = 0x00000000000000000000000000000000000000b2;
    address constant DVN_C = 0x00000000000000000000000000000000000000C3;

    function test_everyFieldSurvivesTheRoundTrip() public pure {
        LayerZeroConfig memory lz;
        lz.blockConfirmations = 15;
        lz.requiredDVNs = _addresses(DVN_A, DVN_B);
        lz.optionalDVNs = _addresses(DVN_C);
        lz.optionalDVNThreshold = 1;

        UlnConfig memory decoded = _encoded(lz);

        assertEq(decoded.confirmations, 15, "confirmations");
        assertEq(decoded.requiredDVNCount, 2, "requiredDVNCount");
        assertEq(decoded.optionalDVNCount, 1, "optionalDVNCount");
        assertEq(decoded.optionalDVNThreshold, 1, "optionalDVNThreshold");
        assertEq(decoded.requiredDVNs.length, 2, "requiredDVNs.length");
        assertEq(decoded.requiredDVNs[0], DVN_A, "requiredDVNs[0]");
        assertEq(decoded.requiredDVNs[1], DVN_B, "requiredDVNs[1]");
        assertEq(decoded.optionalDVNs.length, 1, "optionalDVNs.length");
        assertEq(decoded.optionalDVNs[0], DVN_C, "optionalDVNs[0]");
    }

    /// @dev The one substitution the encoder makes, and the reason it is not `optionalDVNs.length`: to the
    ///      ULN a count of `0` means "inherit the endpoint's default optional set", not "no optional DVNs".
    ///      A chain configured with none would silently verify through LayerZero's defaults instead — a
    ///      config that reads as strict and behaves as permissive, which nothing downstream would reveal.
    function test_anEmptyOptionalSetOptsOutRatherThanInheritingTheDefault() public pure {
        LayerZeroConfig memory lz;
        lz.requiredDVNs = _addresses(DVN_A);

        UlnConfig memory decoded = _encoded(lz);

        assertEq(decoded.optionalDVNCount, ChainConfigLib.NIL_DVN_COUNT, "empty optional set must encode NONE");
        assertNotEq(decoded.optionalDVNCount, 0, "0 would mean: inherit the endpoint default");
        assertEq(decoded.optionalDVNs.length, 0, "and the list itself stays empty");
    }

    /// @dev The ULN reads the counts, not the array lengths, so the two disagreeing is the failure this
    ///      encoder exists to make impossible. Fuzzed over both lengths because the counts are `uint8` casts
    ///      of `uint256` lengths, and a cast is where that stops holding
    function test_countsAlwaysMatchTheListsTheyDescribe(uint8 required, uint8 optional) public pure {
        required = uint8(bound(required, 1, 8));
        optional = uint8(bound(optional, 1, 8));

        LayerZeroConfig memory lz;
        lz.requiredDVNs = _ascending(required, 0x100);
        lz.optionalDVNs = _ascending(optional, 0x200);
        lz.optionalDVNThreshold = 1;

        UlnConfig memory decoded = _encoded(lz);

        assertEq(decoded.requiredDVNCount, decoded.requiredDVNs.length, "requiredDVNCount");
        assertEq(decoded.optionalDVNCount, decoded.optionalDVNs.length, "optionalDVNCount");
    }

    /// @dev The ULN requires both lists sorted ascending and rejects the config otherwise, so the order the
    ///      config was written in has to be the order the endpoint receives. Encoding must not reorder, and
    ///      an unsorted config must reach the endpoint unsorted rather than be quietly repaired here —
    ///      `ChainConfigDvnParsing.t.sol` is what holds the configs themselves to being sorted
    function test_encodingPreservesOrderRatherThanSortingIt() public pure {
        LayerZeroConfig memory lz;
        lz.requiredDVNs = _addresses(DVN_C, DVN_A);

        UlnConfig memory decoded = _encoded(lz);

        assertEq(decoded.requiredDVNs[0], DVN_C, "order is the config's, not the encoder's");
        assertEq(decoded.requiredDVNs[1], DVN_A, "order is the config's, not the encoder's");
    }

    function _encoded(LayerZeroConfig memory lz) private pure returns (UlnConfig memory) {
        return abi.decode(ChainConfigLib.encodeUlnConfig(lz), (UlnConfig));
    }

    function _addresses(address a) private pure returns (address[] memory xs) {
        xs = new address[](1);
        xs[0] = a;
    }

    function _addresses(address a, address b) private pure returns (address[] memory xs) {
        xs = new address[](2);
        xs[0] = a;
        xs[1] = b;
    }

    function _ascending(uint8 count, uint160 start) private pure returns (address[] memory xs) {
        xs = new address[](count);
        for (uint256 i; i < count; i++) {
            xs[i] = address(start + uint160(i));
        }
    }
}
