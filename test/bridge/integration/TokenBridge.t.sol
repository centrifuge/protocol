// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import "../../core/spoke/integration/BaseTest.sol";

import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";

import {ITokenBridge} from "../../../src/bridge/interfaces/ITokenBridge.sol";

abstract contract TokenBridgeBaseTest is BaseTest {
    uint128 constant DEFAULT_AMOUNT = 100_000_000;

    ShareClassId scId;

    AssetId assetId;
    address vault;
    IShareToken shareToken;

    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    address relayer = makeAddr("relayer");

    uint256 constant DESTINATION_CHAIN_ID = 2031;
    uint16 constant DESTINATION_CENT_ID = OTHER_CHAIN_ID;

    function setUp() public override {
        super.setUp();

        scId = ShareClassId.wrap(defaultShareClassId);

        (, address vaultAddress, uint128 createdAssetId) = deployVault(
            VaultKind.SyncDepositAsyncRedeem,
            18,
            address(freelyTransferableHook),
            defaultShareClassId,
            address(erc20),
            erc20TokenId,
            OTHER_CHAIN_ID
        );
        assetId = AssetId.wrap(createdAssetId);
        vault = vaultAddress;
        shareToken = spoke.shareToken(POOL_A, scId);

        tokenBridge.file("centrifugeId", DESTINATION_CHAIN_ID, DESTINATION_CENT_ID);

        vm.deal(user, 1 ether);
    }
}

contract TokenBridgeSendTest is TokenBridgeBaseTest {
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testSendSuccess() public {
        uint128 extraGasLimit = 50_000;
        uint128 remoteExtraGasLimit = 100_000;

        bytes memory payload =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), extraGasLimit, remoteExtraGasLimit);
        tokenBridge.trustedCall(POOL_A, scId, payload);

        depositSync(vault, user, DEFAULT_AMOUNT);

        uint256 shareBalance = shareToken.balanceOf(user);
        assertGt(shareBalance, 0);

        vm.prank(user);
        shareToken.approve(address(tokenBridge), shareBalance);

        vm.expectCall(
            address(messageDispatcher),
            0.1 ether,
            abi.encodeWithSignature(
                "sendInitiateTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                DESTINATION_CENT_ID,
                POOL_A,
                scId,
                receiver.toBytes32(),
                uint128(shareBalance),
                extraGasLimit,
                remoteExtraGasLimit,
                address(user)
            )
        );

        vm.prank(user);
        tokenBridge.send{
            value: 0.1 ether
        }(address(shareToken), shareBalance, receiver.toBytes32(), DESTINATION_CHAIN_ID, user);

        assertEq(shareToken.balanceOf(address(tokenBridge)), 0);
        assertGt(user.balance, 0.99 ether); // Got refunded
    }

    /// forge-config: default.isolate = true
    function testSendWithRelayerSuccess() public {
        tokenBridge.file("relayer", relayer);

        bytes memory payload = abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), 0, 0);
        tokenBridge.trustedCall(POOL_A, scId, payload);

        depositSync(vault, user, DEFAULT_AMOUNT);

        uint256 shareBalance = shareToken.balanceOf(user);
        assertGt(shareBalance, 0);

        vm.prank(user);
        shareToken.approve(address(tokenBridge), shareBalance);

        vm.expectCall(
            address(messageDispatcher),
            0.1 ether,
            abi.encodeWithSignature(
                "sendInitiateTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                DESTINATION_CENT_ID,
                POOL_A,
                scId,
                receiver.toBytes32(),
                uint128(shareBalance / 2),
                0,
                0,
                address(relayer)
            ),
            2
        );

        // Call twice to test approval reuse
        vm.prank(user);
        tokenBridge.send{
            value: 0.1 ether
        }(address(shareToken), shareBalance / 2, receiver.toBytes32(), DESTINATION_CHAIN_ID, user);

        vm.prank(user);
        tokenBridge.send{
            value: 0.1 ether
        }(address(shareToken), shareBalance / 2, receiver.toBytes32(), DESTINATION_CHAIN_ID, user);

        assertEq(shareToken.balanceOf(address(tokenBridge)), 0);
        assertGt(relayer.balance, 0.09 ether); // Eth sent to relayer
    }
}
