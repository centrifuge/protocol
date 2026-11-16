// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestId} from "../../src/core/types/RequestId.sol";

import {RequestType, RequestMessageLib} from "../../src/vaults/messaging/libraries/RequestMessageLib.sol";

import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";

import "forge-std/Test.sol";

/// @dev The spoke-to-hub request wire. Only exercised indirectly through `OrderBook` otherwise, so
///      the encoding is pinned here: the hub reads the request id out of the leading word and the
///      amount after it, and a payload of the wrong type must not decode at all.
contract RequestMessageLibTest is Test {
    using RequestMessageLib for *;

    function testDepositRequest(RequestId investor, uint128 amount) public pure {
        RequestMessageLib.DepositRequest memory a = RequestMessageLib.DepositRequest(investor, amount);
        RequestMessageLib.DepositRequest memory b = a.serialize().deserializeDepositRequest();

        assertEq(a.requestId.raw(), b.requestId.raw());
        assertEq(a.amount, b.amount);
        assertEq(uint8(a.serialize().requestType()), uint8(RequestType.DepositRequest));

        // 1 byte type + 32 bytes investor (the vault-namespaced request id) + 16 bytes amount
        assertEq(a.serialize().length, 1 + 32 + 16);
    }

    function testRedeemRequest(RequestId investor, uint128 amount) public pure {
        RequestMessageLib.RedeemRequest memory a = RequestMessageLib.RedeemRequest(investor, amount);
        RequestMessageLib.RedeemRequest memory b = a.serialize().deserializeRedeemRequest();

        assertEq(a.requestId.raw(), b.requestId.raw());
        assertEq(a.amount, b.amount);
        assertEq(uint8(a.serialize().requestType()), uint8(RequestType.RedeemRequest));
        assertEq(a.serialize().length, 1 + 32 + 16);
    }

    /// @dev The two payloads are the same shape, so only the type byte separates them. If either
    ///      deserializer accepted the other's payload a redeem would settle a deposit order.
    function testSidesAreNotInterchangeable(RequestId investor, uint128 amount) public {
        bytes memory deposit = RequestMessageLib.DepositRequest(investor, amount).serialize();
        bytes memory redeem = RequestMessageLib.RedeemRequest(investor, amount).serialize();

        vm.expectRevert(RequestMessageLib.UnknownRequestType.selector);
        this.deserializeRedeem(deposit);

        vm.expectRevert(RequestMessageLib.UnknownRequestType.selector);
        this.deserializeDeposit(redeem);
    }

    /// @dev The id the vault stamps is the id the hub keys its order by; nothing in transit truncates
    ///      the vault half or the local half.
    function testCarriesTheVaultNamespacedId(address vault, uint96 localId, uint128 amount) public pure {
        RequestId id = VaultRequestIdLib.from(vault, localId);

        bytes memory encoded = RequestMessageLib.DepositRequest(id, amount).serialize();
        assertEq(encoded, abi.encodePacked(uint8(RequestType.DepositRequest), bytes32(id.raw()), amount));

        RequestId recovered = encoded.deserializeDepositRequest().requestId;
        assertEq(VaultRequestIdLib.vaultOf(recovered), vault);
        assertEq(VaultRequestIdLib.localIdOf(recovered), localId);
    }

    function testDeserializeRequestReadsEitherSide(RequestId id, uint128 amount) public pure {
        (bool isDeposit, RequestId requestId, uint128 got) =
            RequestMessageLib.DepositRequest(id, amount).serialize().deserializeRequest();
        assertTrue(isDeposit);
        assertEq(requestId.raw(), id.raw());
        assertEq(got, amount);

        (isDeposit, requestId, got) = RequestMessageLib.RedeemRequest(id, amount).serialize().deserializeRequest();
        assertFalse(isDeposit);
        assertEq(requestId.raw(), id.raw());
        assertEq(got, amount);
    }

    function testDeserializeRequestRefusesAnyOtherType(bytes32 id, uint128 amount) public {
        bytes memory data = abi.encodePacked(uint8(0), id, amount);

        vm.expectRevert(RequestMessageLib.UnknownRequestType.selector);
        this.deserializeAny(data);
    }

    function deserializeAny(bytes memory data) external pure {
        data.deserializeRequest();
    }

    function deserializeDeposit(bytes memory data) external pure {
        data.deserializeDepositRequest();
    }

    function deserializeRedeem(bytes memory data) external pure {
        data.deserializeRedeemRequest();
    }
}
