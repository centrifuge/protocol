// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../../src/core/types/ShareClassId.sol";

import {BaseDecoder} from "../../../../../src/managers/spoke/decoders/BaseDecoder.sol";
import {VaultDecoder} from "../../../../../src/managers/spoke/decoders/VaultDecoder.sol";

import "forge-std/Test.sol";

contract VaultDecoderTest is Test {
    VaultDecoder decoder;

    function setUp() public {
        decoder = new VaultDecoder();
    }
}

contract VaultDecoderERC4626Test is VaultDecoderTest {
    function testDeposit() public {
        uint256 assets = 1000e18;
        address receiver = makeAddr("receiver");

        bytes memory addressesFound = decoder.deposit(assets, receiver);

        bytes memory expected = abi.encodePacked(receiver);
        assertEq(addressesFound, expected);
    }

    function testDepositFuzz(uint256 assets, address receiver) public view {
        bytes memory addressesFound = decoder.deposit(assets, receiver);

        bytes memory expected = abi.encodePacked(receiver);
        assertEq(addressesFound, expected);
    }

    function testMint() public {
        uint256 shares = 1000e18;
        address receiver = makeAddr("receiver");

        bytes memory addressesFound = decoder.mint(shares, receiver);

        bytes memory expected = abi.encodePacked(receiver);
        assertEq(addressesFound, expected);
    }

    function testMintFuzz(uint256 shares, address receiver) public view {
        bytes memory addressesFound = decoder.mint(shares, receiver);

        bytes memory expected = abi.encodePacked(receiver);
        assertEq(addressesFound, expected);
    }

    function testWithdraw() public {
        uint256 assets = 1000e18;
        address receiver = makeAddr("receiver");
        address owner = makeAddr("owner");

        bytes memory addressesFound = decoder.withdraw(assets, receiver, owner);

        bytes memory expected = abi.encodePacked(receiver, owner);
        assertEq(addressesFound, expected);
    }

    function testWithdrawFuzz(uint256 assets, address receiver, address owner) public view {
        bytes memory addressesFound = decoder.withdraw(assets, receiver, owner);

        bytes memory expected = abi.encodePacked(receiver, owner);
        assertEq(addressesFound, expected);
    }

    function testRedeem() public {
        uint256 shares = 1000e18;
        address receiver = makeAddr("receiver");
        address owner = makeAddr("owner");

        bytes memory addressesFound = decoder.redeem(shares, receiver, owner);

        bytes memory expected = abi.encodePacked(receiver, owner);
        assertEq(addressesFound, expected);
    }

    function testRedeemFuzz(uint256 shares, address receiver, address owner) public view {
        bytes memory addressesFound = decoder.redeem(shares, receiver, owner);

        bytes memory expected = abi.encodePacked(receiver, owner);
        assertEq(addressesFound, expected);
    }
}

contract VaultDecoderERC7540Test is VaultDecoderTest {
    function testRequestDeposit() public {
        uint256 assets = 1000e18;
        address controller = makeAddr("controller");
        address owner = makeAddr("owner");

        bytes memory addressesFound = decoder.requestDeposit(assets, controller, owner);

        bytes memory expected = abi.encodePacked(controller, owner);
        assertEq(addressesFound, expected);
    }

    function testRequestDepositFuzz(uint256 assets, address controller, address owner) public view {
        bytes memory addressesFound = decoder.requestDeposit(assets, controller, owner);

        bytes memory expected = abi.encodePacked(controller, owner);
        assertEq(addressesFound, expected);
    }

    function testRequestRedeem() public {
        uint256 shares = 1000e18;
        address controller = makeAddr("controller");
        address owner = makeAddr("owner");

        bytes memory addressesFound = decoder.requestRedeem(shares, controller, owner);

        bytes memory expected = abi.encodePacked(controller, owner);
        assertEq(addressesFound, expected);
    }

    function testRequestRedeemFuzz(uint256 shares, address controller, address owner) public view {
        bytes memory addressesFound = decoder.requestRedeem(shares, controller, owner);

        bytes memory expected = abi.encodePacked(controller, owner);
        assertEq(addressesFound, expected);
    }
}

contract VaultDecoderERC7887Test is VaultDecoderTest {
    function testCancelDepositRequest() public {
        uint256 requestId = 123;
        address controller = makeAddr("controller");

        bytes memory addressesFound = decoder.cancelDepositRequest(requestId, controller);

        bytes memory expected = abi.encodePacked(controller);
        assertEq(addressesFound, expected);
    }

    function testCancelDepositRequestFuzz(uint256 requestId, address controller) public view {
        bytes memory addressesFound = decoder.cancelDepositRequest(requestId, controller);

        bytes memory expected = abi.encodePacked(controller);
        assertEq(addressesFound, expected);
    }

    function testCancelRedeemRequest() public {
        uint256 requestId = 123;
        address controller = makeAddr("controller");

        bytes memory addressesFound = decoder.cancelRedeemRequest(requestId, controller);

        bytes memory expected = abi.encodePacked(controller);
        assertEq(addressesFound, expected);
    }

    function testCancelRedeemRequestFuzz(uint256 requestId, address controller) public view {
        bytes memory addressesFound = decoder.cancelRedeemRequest(requestId, controller);

        bytes memory expected = abi.encodePacked(controller);
        assertEq(addressesFound, expected);
    }

    function testClaimCancelDepositRequest() public {
        uint256 requestId = 123;
        address receiver = makeAddr("receiver");
        address controller = makeAddr("controller");

        bytes memory addressesFound = decoder.claimCancelDepositRequest(requestId, receiver, controller);

        bytes memory expected = abi.encodePacked(receiver, controller);
        assertEq(addressesFound, expected);
    }

    function testClaimCancelDepositRequestFuzz(uint256 requestId, address receiver, address controller) public view {
        bytes memory addressesFound = decoder.claimCancelDepositRequest(requestId, receiver, controller);

        bytes memory expected = abi.encodePacked(receiver, controller);
        assertEq(addressesFound, expected);
    }

    function testClaimCancelRedeemRequest() public {
        uint256 requestId = 123;
        address receiver = makeAddr("receiver");
        address controller = makeAddr("controller");

        bytes memory addressesFound = decoder.claimCancelRedeemRequest(requestId, receiver, controller);

        bytes memory expected = abi.encodePacked(receiver, controller);
        assertEq(addressesFound, expected);
    }

    function testClaimCancelRedeemRequestFuzz(uint256 requestId, address receiver, address controller) public view {
        bytes memory addressesFound = decoder.claimCancelRedeemRequest(requestId, receiver, controller);

        bytes memory expected = abi.encodePacked(receiver, controller);
        assertEq(addressesFound, expected);
    }
}

contract VaultDecoderInheritedFunctionsTest is VaultDecoderTest {
    function testApprove() public {
        address spender = makeAddr("spender");
        uint256 amount = 1000e18;

        bytes memory addressesFound = decoder.approve(spender, amount);

        bytes memory expected = abi.encodePacked(spender);
        assertEq(addressesFound, expected);
    }

    function testDepositBalanceSheet() public {
        PoolId poolId = PoolId.wrap(1);
        ShareClassId scId = ShareClassId.wrap(bytes16("sc1"));
        address asset = makeAddr("asset");
        uint256 amount = 1000e18;
        uint128 minSharesOut = 900e18;

        bytes memory addressesFound = decoder.deposit(poolId, scId, asset, amount, minSharesOut);

        bytes memory expected = abi.encodePacked(poolId, scId, asset);
        assertEq(addressesFound, expected);
    }

    function testWithdrawBalanceSheet() public {
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
