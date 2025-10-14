// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {BaseDecoder} from "../../../../../src/managers/spoke/decoders/BaseDecoder.sol";
import {CircleDecoder} from "../../../../../src/managers/spoke/decoders/CircleDecoder.sol";

import "forge-std/Test.sol";

contract CircleDecoderTest is Test {
    CircleDecoder decoder;

    function setUp() public {
        decoder = new CircleDecoder();
    }
}

contract CircleDecoderDepositForBurnTest is CircleDecoderTest {
    function testDepositForBurnSuccess() public {
        uint256 amount = 1000e6;
        uint32 destinationDomain = 7;
        bytes32 mintRecipient = bytes32(uint256(uint160(makeAddr("recipient"))));
        address burnToken = makeAddr("burnToken");

        bytes memory addressesFound = decoder.depositForBurn(amount, destinationDomain, mintRecipient, burnToken);

        bytes memory expected = abi.encodePacked(destinationDomain, mintRecipient, burnToken);
        assertEq(addressesFound, expected);
    }

    function testDepositForBurnFuzz(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        public
        view
    {
        bytes memory addressesFound = decoder.depositForBurn(amount, destinationDomain, mintRecipient, burnToken);

        bytes memory expected = abi.encodePacked(destinationDomain, mintRecipient, burnToken);
        assertEq(addressesFound, expected);
    }

    function testDepositForBurnZeroAmount() public {
        uint32 destinationDomain = 7;
        bytes32 mintRecipient = bytes32(uint256(uint160(makeAddr("recipient"))));
        address burnToken = makeAddr("burnToken");

        bytes memory addressesFound = decoder.depositForBurn(0, destinationDomain, mintRecipient, burnToken);

        bytes memory expected = abi.encodePacked(destinationDomain, mintRecipient, burnToken);
        assertEq(addressesFound, expected);
    }
}

contract CircleDecoderReceiveMessageTest is CircleDecoderTest {
    function testReceiveMessageSuccess() public view {
        bytes memory message = hex"1234567890abcdef";
        bytes memory attestation = hex"fedcba0987654321";

        bytes memory addressesFound = decoder.receiveMessage(message, attestation);

        assertEq(addressesFound.length, 0);
        assertEq(addressesFound, "");
    }

    function testReceiveMessageEmptyInputs() public view {
        bytes memory message = "";
        bytes memory attestation = "";

        bytes memory addressesFound = decoder.receiveMessage(message, attestation);

        assertEq(addressesFound.length, 0);
    }

    function testReceiveMessageFuzz(bytes memory message, bytes memory attestation) public view {
        bytes memory addressesFound = decoder.receiveMessage(message, attestation);

        assertEq(addressesFound.length, 0);
    }
}

contract CircleDecoderInheritedFunctionsTest is CircleDecoderTest {
    function testApprove() public {
        address spender = makeAddr("spender");
        uint256 amount = 1000e18;

        bytes memory addressesFound = decoder.approve(spender, amount);

        bytes memory expected = abi.encodePacked(spender);
        assertEq(addressesFound, expected);
    }

    function testDeposit() public {
        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16("sc1"));
        address asset = makeAddr("asset");
        uint256 amount = 1000e18;
        uint128 minSharesOut = 900e18;

        bytes memory addressesFound = decoder.deposit(poolId, scId, asset, amount, minSharesOut);

        bytes memory expected = abi.encodePacked(poolId, scId, asset);
        assertEq(addressesFound, expected);
    }

    function testWithdraw() public {
        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16("sc1"));
        address asset = makeAddr("asset");
        uint256 shares = 1000e18;
        address receiver = makeAddr("receiver");
        uint128 minAssetsOut = 900e18;

        bytes memory addressesFound = decoder.withdraw(poolId, scId, asset, shares, receiver, minAssetsOut);

        bytes memory expected = abi.encodePacked(poolId, scId, asset, receiver);
        assertEq(addressesFound, expected);
    }

    function testFallbackReverts() public {
        bytes memory data = abi.encodeWithSignature("nonExistentFunction()");

        vm.expectRevert(abi.encodeWithSelector(BaseDecoder.FunctionNotImplemented.selector, data));
        (bool success,) = address(decoder).call(data);
        success; // Suppress warning
    }
}
