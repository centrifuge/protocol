// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    RequestCallbackType,
    RequestCallbackMessageLib
} from "../../../../src/common/libraries/RequestCallbackMessageLib.sol";

import "forge-std/Test.sol";

contract TestRequestCallbackMessageLibIdentities is Test {
    using RequestCallbackMessageLib for *;

    function testRequestCallbackType(uint8 messageType) public pure {
        vm.assume(messageType <= uint8(type(RequestCallbackType).max));

        bytes memory data = abi.encodePacked(messageType);
        RequestCallbackType result = RequestCallbackMessageLib.requestCallbackType(data);

        assertEq(uint8(result), messageType);
    }

    function testApprovedDeposits(uint128 assetAmount, uint128 pricePoolPerAsset) public pure {
        RequestCallbackMessageLib.ApprovedDeposits memory a =
            RequestCallbackMessageLib.ApprovedDeposits({assetAmount: assetAmount, pricePoolPerAsset: pricePoolPerAsset});
        RequestCallbackMessageLib.ApprovedDeposits memory b = a.serialize().deserializeApprovedDeposits();

        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.pricePoolPerAsset, b.pricePoolPerAsset);

        assertEq(
            uint8(RequestCallbackMessageLib.requestCallbackType(a.serialize())),
            uint8(RequestCallbackType.ApprovedDeposits)
        );

        // 1 byte type + 16 bytes assetAmount + 16 bytes pricePoolPerAsset
        assertEq(a.serialize().length, 1 + 16 + 16);
    }

    function testIssuedShares(uint128 shareAmount, uint128 pricePoolPerShare) public pure {
        RequestCallbackMessageLib.IssuedShares memory a =
            RequestCallbackMessageLib.IssuedShares({shareAmount: shareAmount, pricePoolPerShare: pricePoolPerShare});
        RequestCallbackMessageLib.IssuedShares memory b = a.serialize().deserializeIssuedShares();

        assertEq(a.shareAmount, b.shareAmount);
        assertEq(a.pricePoolPerShare, b.pricePoolPerShare);

        assertEq(
            uint8(RequestCallbackMessageLib.requestCallbackType(a.serialize())), uint8(RequestCallbackType.IssuedShares)
        );

        // 1 byte type + 16 bytes shareAmount + 16 bytes pricePoolPerShare
        assertEq(a.serialize().length, 1 + 16 + 16);
    }

    function testRevokedShares(uint128 assetAmount, uint128 shareAmount, uint128 pricePoolPerShare) public pure {
        RequestCallbackMessageLib.RevokedShares memory a = RequestCallbackMessageLib.RevokedShares({
            assetAmount: assetAmount,
            shareAmount: shareAmount,
            pricePoolPerShare: pricePoolPerShare
        });
        RequestCallbackMessageLib.RevokedShares memory b = a.serialize().deserializeRevokedShares();

        assertEq(a.assetAmount, b.assetAmount);
        assertEq(a.shareAmount, b.shareAmount);
        assertEq(a.pricePoolPerShare, b.pricePoolPerShare);

        assertEq(
            uint8(RequestCallbackMessageLib.requestCallbackType(a.serialize())),
            uint8(RequestCallbackType.RevokedShares)
        );

        // 1 byte type + 16 bytes assetAmount + 16 bytes shareAmount + 16 bytes pricePoolPerShare
        assertEq(a.serialize().length, 1 + 16 + 16 + 16);
    }

    function testFulfilledDepositRequest(
        bytes32 investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) public pure {
        RequestCallbackMessageLib.FulfilledDepositRequest memory a = RequestCallbackMessageLib.FulfilledDepositRequest({
            investor: investor,
            fulfilledAssetAmount: fulfilledAssetAmount,
            fulfilledShareAmount: fulfilledShareAmount,
            cancelledAssetAmount: cancelledAssetAmount
        });
        RequestCallbackMessageLib.FulfilledDepositRequest memory b = a.serialize().deserializeFulfilledDepositRequest();

        assertEq(a.investor, b.investor);
        assertEq(a.fulfilledAssetAmount, b.fulfilledAssetAmount);
        assertEq(a.fulfilledShareAmount, b.fulfilledShareAmount);
        assertEq(a.cancelledAssetAmount, b.cancelledAssetAmount);

        assertEq(
            uint8(RequestCallbackMessageLib.requestCallbackType(a.serialize())),
            uint8(RequestCallbackType.FulfilledDepositRequest)
        );

        // 1 byte type + 32 bytes investor + 16 bytes fulfilledAssetAmount + 16 bytes fulfilledShareAmount + 16 bytes
        // cancelledAssetAmount
        assertEq(a.serialize().length, 1 + 32 + 16 + 16 + 16);
    }

    function testFulfilledRedeemRequest(
        bytes32 investor,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) public pure {
        RequestCallbackMessageLib.FulfilledRedeemRequest memory a = RequestCallbackMessageLib.FulfilledRedeemRequest({
            investor: investor,
            fulfilledAssetAmount: fulfilledAssetAmount,
            fulfilledShareAmount: fulfilledShareAmount,
            cancelledShareAmount: cancelledShareAmount
        });
        RequestCallbackMessageLib.FulfilledRedeemRequest memory b = a.serialize().deserializeFulfilledRedeemRequest();

        assertEq(a.investor, b.investor);
        assertEq(a.fulfilledAssetAmount, b.fulfilledAssetAmount);
        assertEq(a.fulfilledShareAmount, b.fulfilledShareAmount);
        assertEq(a.cancelledShareAmount, b.cancelledShareAmount);

        assertEq(
            uint8(RequestCallbackMessageLib.requestCallbackType(a.serialize())),
            uint8(RequestCallbackType.FulfilledRedeemRequest)
        );

        // 1 byte type + 32 bytes investor + 16 bytes fulfilledAssetAmount + 16 bytes fulfilledShareAmount + 16 bytes
        // cancelledShareAmount
        assertEq(a.serialize().length, 1 + 32 + 16 + 16 + 16);
    }
}
