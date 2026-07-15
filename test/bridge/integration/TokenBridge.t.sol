// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {SyncDepositVault} from "../../../src/vaults/SyncDepositVault.sol";

import {TokenBridge} from "../../../src/bridge/TokenBridge.sol";
import {ITokenBridge} from "../../../src/bridge/interfaces/ITokenBridge.sol";
import {ThreeChainEndToEndDeployment} from "../../integration/ThreeChainEndToEnd.t.sol";

abstract contract TokenBridgeBaseTest is ThreeChainEndToEndDeployment {
    using CastLib for *;

    uint256 constant DESTINATION_CHAIN_ID = 2031;
    uint128 constant DEFAULT_AMOUNT = 100_000_000;

    TokenBridge tokenBridge;
    SyncDepositVault vault;
    IShareToken shareToken;

    address user = makeAddr("user");
    address receiver = makeAddr("receiver");
    address relayer = makeAddr("relayer");

    receive() external payable {}

    function _setUpBridge() internal {
        // Source: same-chain (hub + spoke on A)
        _configurePool(true);
        _configurePrices(d18(1, 1), d18(1, 1));

        // Destination: spoke on C — _configurePoolInSpoke wires pool-specific adapters A↔C
        _setSpoke(deployC, CENTRIFUGE_ID_C, dest);
        _configurePoolInSpoke(dest);

        // Deploy sync vault on chain A
        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, s.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS, REFUND
        );
        h.hub.updateContract{value: GAS}(
            POOL_A,
            SC_1,
            s.centrifugeId,
            address(s.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(type(uint128).max),
            EXTRA_GAS,
            REFUND
        );
        vm.stopPrank();

        shareToken = s.spoke.shareToken(POOL_A, SC_1);
        vault = SyncDepositVault(shareToken.vault(address(s.usdc)));

        tokenBridge = deployA.tokenBridge();
        vm.prank(address(h.root));
        tokenBridge.rely(address(this));
        tokenBridge.file("centrifugeId", DESTINATION_CHAIN_ID, CENTRIFUGE_ID_C);

        vm.deal(user, 1 ether);
    }

    function depositSync(address _investor, uint256 amount) internal {
        s.usdc.mint(_investor, amount);
        vm.startPrank(_investor);
        s.usdc.approve(address(vault), amount);
        vault.deposit(amount, _investor);
        vm.stopPrank();
    }
}

contract TokenBridgeSendTest is TokenBridgeBaseTest {
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testSendSuccess() public {
        _setUpBridge();

        uint128 extraGasLimit = 50_000;
        uint128 remoteExtraGasLimit = 100_000;

        bytes memory payload =
            abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), extraGasLimit, remoteExtraGasLimit);
        tokenBridge.trustedCall(POOL_A, SC_1, payload);

        depositSync(user, DEFAULT_AMOUNT);

        uint256 shareBalance = shareToken.balanceOf(user);
        assertGt(shareBalance, 0);

        vm.prank(user);
        shareToken.approve(address(tokenBridge), shareBalance);

        vm.expectCall(
            address(deployA.messageDispatcher()),
            0.1 ether,
            abi.encodeWithSignature(
                "sendInitiateTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_C,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                uint128(shareBalance),
                extraGasLimit,
                remoteExtraGasLimit,
                address(user)
            )
        );

        vm.prank(user);
        tokenBridge.send{value: 0.1 ether}(
            address(shareToken), shareBalance, receiver.toBytes32(), DESTINATION_CHAIN_ID, user
        );

        assertEq(shareToken.balanceOf(address(tokenBridge)), 0);
        assertGt(user.balance, 0.99 ether); // Got refunded
    }

    /// forge-config: default.isolate = true
    function testSendWithRelayerSourceHubRefundsUser() public {
        // This fixture deploys the pool's hub and the bridge on the same chain (A), so every `send` is a
        // hub->spoke single-leg transfer. Even with a relayer configured, there is no second leg to fund, so
        // the overpayment is refunded directly to the user rather than the relayer. The relayer-funded
        // spoke->hub->spoke routing is covered at the unit level (see TokenBridge.t.sol:testSendWithRelayer).
        _setUpBridge();

        tokenBridge.file("relayer", relayer);

        bytes memory payload = abi.encode(uint8(ITokenBridge.TrustedCall.SetGasLimits), 0, 0);
        tokenBridge.trustedCall(POOL_A, SC_1, payload);

        depositSync(user, DEFAULT_AMOUNT);

        uint256 shareBalance = shareToken.balanceOf(user);
        assertGt(shareBalance, 0);

        vm.prank(user);
        shareToken.approve(address(tokenBridge), shareBalance);

        vm.expectCall(
            address(deployA.messageDispatcher()),
            0.1 ether,
            abi.encodeWithSignature(
                "sendInitiateTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,uint128,address)",
                CENTRIFUGE_ID_C,
                POOL_A,
                SC_1,
                receiver.toBytes32(),
                uint128(shareBalance / 2),
                0,
                0,
                address(user)
            ),
            2
        );

        vm.prank(user);
        tokenBridge.send{value: 0.1 ether}(
            address(shareToken), shareBalance / 2, receiver.toBytes32(), DESTINATION_CHAIN_ID, user
        );

        vm.prank(user);
        tokenBridge.send{value: 0.1 ether}(
            address(shareToken), shareBalance / 2, receiver.toBytes32(), DESTINATION_CHAIN_ID, user
        );

        assertEq(shareToken.balanceOf(address(tokenBridge)), 0);
        assertEq(relayer.balance, 0); // Relayer bypassed for a hub-sourced transfer
        assertGt(user.balance, 0.99 ether); // User got refunded
    }
}
