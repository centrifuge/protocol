// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

// Test that funcion composition of serialize and deserialize is the identity: I = deserialize º serialize
contract MessageLibTest is Test {
    using MessageLib for *;

    function testRegisterAsset() public pure {
        MessageLib.RegisterAsset memory a = MessageLib.RegisterAsset({assetId: 1, name: "n", symbol: "s", decimals: 4});
        MessageLib.RegisterAsset memory b = MessageLib.deserializeRegisterAsset(a.serialize());

        assertEq(a.assetId, b.assetId);
        assertEq(a.name, b.name);
        assertEq(a.symbol, b.symbol);
        assertEq(a.decimals, b.decimals);
    }

    // TODO: rest of the messages
}
