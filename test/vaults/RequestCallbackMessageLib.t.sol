// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestId} from "../../src/core/types/RequestId.sol";

import {
    RequestCallbackMessageLib,
    RequestCallbackType
} from "../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";

import "forge-std/Test.sol";

/// @dev The wire format every hub settlement arrives in. Four callback types, each a fixed-width
///      packed encoding, and the vault acts on whatever comes out of them — so what these tests pin
///      is that a message decodes to exactly what was encoded, that a type tag cannot be read as
///      another type's payload, and that a short message is refused rather than read past its end.
contract RequestCallbackMessageLibTest is Test {
    using RequestCallbackMessageLib for *;

    /// @dev Every type's payload starts at the same two offsets, so a decoder reading the wrong one
    ///      would silently succeed. Each round trip is checked against its own type tag.
    /// @dev Gross and net are distinct legs and the vault treats them differently: gross retires the
    ///      pending request and releases the reservation, net is what the investor may claim. Swapping
    ///      them would strand the difference or over-credit it, so the order is asserted, not assumed.
    function testFuzzCancelledDeposit(RequestId requestId, uint128 gross, uint128 net) public pure {
        bytes memory encoded = RequestCallbackMessageLib.CancelledDeposit(requestId, gross, net).serialize();

        assertEq(uint8(encoded.requestCallbackType()), uint8(RequestCallbackType.CancelledDeposit));

        RequestCallbackMessageLib.CancelledDeposit memory decoded = encoded.deserializeCancelledDeposit();
        assertEq(decoded.requestId.raw(), requestId.raw());
        assertEq(decoded.grossAssetAmount, gross, "gross first");
        assertEq(decoded.netAssetAmount, net, "net second");
    }

    function testFuzzCancelledRedeem(RequestId requestId, uint128 gross, uint128 net) public pure {
        bytes memory encoded = RequestCallbackMessageLib.CancelledRedeem(requestId, gross, net).serialize();

        assertEq(uint8(encoded.requestCallbackType()), uint8(RequestCallbackType.CancelledRedeem));

        RequestCallbackMessageLib.CancelledRedeem memory decoded = encoded.deserializeCancelledRedeem();
        assertEq(decoded.requestId.raw(), requestId.raw());
        assertEq(decoded.grossShareAmount, gross, "gross first");
        assertEq(decoded.netShareAmount, net, "net second");
    }

    /// @dev The atomic settlements share their payload shape with the fulfillment types they subsume,
    ///      so only the tag separates them and the round trip has to pin it.
    function testFuzzSettledDeposit(RequestId requestId, uint128 assets, uint128 shares) public pure {
        bytes memory encoded = RequestCallbackMessageLib.SettledDeposit(requestId, assets, shares).serialize();

        assertEq(uint8(encoded.requestCallbackType()), uint8(RequestCallbackType.SettledDeposit));
        assertEq(encoded.requestId().raw(), requestId.raw());

        RequestCallbackMessageLib.SettledDeposit memory decoded = encoded.deserializeSettledDeposit();
        assertEq(decoded.requestId.raw(), requestId.raw());
        assertEq(decoded.fulfilledAssetAmount, assets, "assets first");
        assertEq(decoded.fulfilledShareAmount, shares, "shares second");
    }

    function testFuzzSettledRedeem(RequestId requestId, uint128 assets, uint128 shares) public pure {
        bytes memory encoded = RequestCallbackMessageLib.SettledRedeem(requestId, assets, shares).serialize();

        assertEq(uint8(encoded.requestCallbackType()), uint8(RequestCallbackType.SettledRedeem));
        assertEq(encoded.requestId().raw(), requestId.raw());

        RequestCallbackMessageLib.SettledRedeem memory decoded = encoded.deserializeSettledRedeem();
        assertEq(decoded.requestId.raw(), requestId.raw());
        assertEq(decoded.fulfilledAssetAmount, assets, "assets first");
        assertEq(decoded.fulfilledShareAmount, shares, "shares second");
    }

    //----------------------------------------------------------------------------------------------
    // Type confusion
    //----------------------------------------------------------------------------------------------

    /// @dev Several types share a payload shape, so nothing but the tag distinguishes them. Every
    ///      decoder must refuse every tag but its own, or a cancellation could be applied as a
    ///      fulfillment (or a revocation's shares read as a fulfillment's).
    function testEveryDecoderRefusesEveryOtherType() public {
        bytes[4] memory messages = [
            RequestCallbackMessageLib.CancelledDeposit(RequestId.wrap(1), 2, 3).serialize(),
            RequestCallbackMessageLib.CancelledRedeem(RequestId.wrap(1), 2, 3).serialize(),
            RequestCallbackMessageLib.SettledDeposit(RequestId.wrap(1), 2, 3).serialize(),
            RequestCallbackMessageLib.SettledRedeem(RequestId.wrap(1), 2, 3).serialize()
        ];

        for (uint256 i; i < messages.length; i++) {
            for (uint256 j; j < messages.length; j++) {
                if (i == j) continue;
                vm.expectRevert(RequestCallbackMessageLib.UnknownRequestCallbackType.selector);
                this.decodeAs(j, messages[i]);
            }
        }
    }

    /// @dev The tag is a raw byte on the wire, so a value past the enum's end has to be rejected by
    ///      the enum conversion rather than read as some neighbouring type.
    function testFuzzAnOutOfRangeTagIsRefused(uint8 tag) public {
        tag = uint8(bound(tag, 5, type(uint8).max));
        bytes memory message = abi.encodePacked(tag, uint256(1), uint128(2), uint128(3));

        vm.expectRevert();
        this.readType(message);
    }

    /// @dev A truncated message must not read past its end: `BytesLib` bounds every read, so a payload
    ///      cut short reverts instead of decoding zeroes into an amount the vault then settles.
    function testFuzzATruncatedPayloadIsRefused(uint256 length) public {
        bytes memory full = RequestCallbackMessageLib.SettledRedeem(RequestId.wrap(1), 2, 3).serialize();
        length = bound(length, 1, full.length - 1);

        bytes memory short = new bytes(length);
        for (uint256 i; i < length; i++) {
            short[i] = full[i];
        }

        vm.expectRevert();
        this.decodeAs(3, short);
    }

    /// @dev External so `vm.expectRevert` sees a call boundary.
    function readType(bytes memory message) external pure returns (uint8) {
        return uint8(message.requestCallbackType());
    }

    function decodeAs(uint256 which, bytes memory message) external pure {
        if (which == 0) message.deserializeCancelledDeposit();
        else if (which == 1) message.deserializeCancelledRedeem();
        else if (which == 2) message.deserializeSettledDeposit();
        else message.deserializeSettledRedeem();
    }
}
