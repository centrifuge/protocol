// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {BridgeCircuitBreaker} from "../../../src/hooks/bridge/BridgeCircuitBreaker.sol";
import {IBridgeCircuitBreaker} from "../../../src/hooks/bridge/interfaces/IBridgeCircuitBreaker.sol";

import {ICircuitBreakerGuard} from "../../../src/managers/spoke/guards/interfaces/ICircuitBreakerGuard.sol";

import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {CentrifugeIntegrationTest} from "../../integration/Integration.t.sol";

contract BridgeCircuitBreakerIntegrationTest is CentrifugeIntegrationTest {
    uint16 constant TARGET = 2;
    uint128 constant AMOUNT = 1000e18;

    address immutable FM = makeAddr("fundManager");
    PoolId POOL_A;
    ShareClassId SC_1;

    BridgeCircuitBreaker hook;
    IShareToken shareToken;
    address immutable investor = makeAddr("investor");

    function setUp() public override {
        super.setUp();

        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);

        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        hub.addShareClass(POOL_A, "Test", "T", bytes32(bytes8(POOL_A.raw())));
        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, FM);
        hub.notifyShareClass{value: 0}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(shareTokenRegistrar))), "", 0, FM
        );
        vm.stopPrank();

        shareToken = IShareToken(address(spokeRegistry.shareToken(POOL_A, SC_1)));
        vm.prank(address(shareTokenRegistrar));
        shareToken.mint(investor, 3 * AMOUNT);

        // The Spoke pulls the shares via a standard transferFrom, so the investor approves it.
        vm.prank(investor);
        shareToken.approve(address(spoke), type(uint256).max);

        // Allow the investor to initiate cross-chain share transfers
        vm.prank(address(spokeHandler));
        spokeRegistry.updateBridger(POOL_A, investor, true);

        hook = new BridgeCircuitBreaker(address(this), address(circuitBreakerGuard), address(this));
        hook.rely(address(hubHandler));

        vm.prank(FM);
        hub.setBridgingHook(POOL_A, address(hook));

        vm.mockCall(
            address(messageDispatcher),
            abi.encodeWithSignature(
                "sendExecuteTransferShares(uint16,uint16,uint64,bytes16,bytes32,uint128,uint128,address)"
            ),
            abi.encode(uint256(0))
        );

        vm.deal(address(root), 1 ether);
    }

    function _fromHub(bytes memory payload) internal {
        hook.fromHub(POOL_A, payload);
    }

    /// forge-config: default.isolate = true
    function testPauseBlocksTransfer() public {
        _fromHub(abi.encode(IBridgeCircuitBreaker.ConfigKind.SetPaused, ShareClassId.unwrap(SC_1), true));

        bytes32 receiver = bytes32(uint256(uint160(makeAddr("receiver"))));
        vm.prank(investor);
        vm.expectRevert(IBridgeCircuitBreaker.Paused.selector);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 3 * AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testRateLimitBlocksTransfer() public {
        // rateMax allows one AMOUNT per window but not two
        uint128 rateMax = AMOUNT + 1;
        uint32 window = 3600;
        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.SetRateLimit,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                rateMax,
                window
            )
        );

        bytes32 key = keccak256(abi.encode(POOL_A, SC_1, LOCAL_CENTRIFUGE_ID));
        bytes32 receiver = bytes32(uint256(uint160(makeAddr("receiver"))));

        vm.prank(investor);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 2 * AMOUNT);

        vm.prank(investor);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICircuitBreakerGuard.ExceedsCumulativeLimit.selector,
                key,
                uint256(AMOUNT),
                uint256(rateMax),
                uint256(window)
            )
        );
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 2 * AMOUNT);

        // After window expires, the rolling window resets and a new transfer succeeds
        vm.warp(block.timestamp + window + 1);
        vm.prank(investor);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testLargeTransferAuthorization() public {
        uint128 rateMax = AMOUNT - 1;
        uint32 window = 3600;
        bytes32 receiver = bytes32(uint256(uint160(makeAddr("receiver"))));
        bytes32 sender_ = bytes32(bytes20(investor));

        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.SetRateLimit,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                rateMax,
                window
            )
        );

        vm.prank(investor);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 3 * AMOUNT);

        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.AuthorizeTransfer,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                TARGET,
                sender_,
                receiver,
                AMOUNT
            )
        );
        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.AuthorizeTransfer,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                TARGET,
                sender_,
                receiver,
                AMOUNT
            )
        );

        vm.prank(investor);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 2 * AMOUNT);

        vm.prank(investor);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), AMOUNT);

        // No authorizations left — hook blocks again, shares returned
        vm.prank(investor);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testCancelledAuthorizationBlocksTransfer() public {
        uint128 rateMax = AMOUNT - 1;
        uint32 window = 3600;
        bytes32 receiver = bytes32(uint256(uint160(makeAddr("receiver"))));
        bytes32 sender_ = bytes32(bytes20(investor));

        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.SetRateLimit,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                rateMax,
                window
            )
        );

        // Authorize then immediately cancel
        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.AuthorizeTransfer,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                TARGET,
                sender_,
                receiver,
                AMOUNT
            )
        );
        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.CancelTransferAuthorizations,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                TARGET,
                sender_,
                receiver,
                AMOUNT
            )
        );

        vm.prank(investor);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 3 * AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testAuthorizationIsKeyedPerSender() public {
        address investor2 = makeAddr("investor2");
        vm.prank(address(shareTokenRegistrar));
        shareToken.mint(investor2, AMOUNT);
        vm.prank(investor2);
        shareToken.approve(address(spoke), type(uint256).max);
        vm.prank(address(spokeHandler));
        spokeRegistry.updateBridger(POOL_A, investor2, true);

        uint128 rateMax = AMOUNT - 1;
        uint32 window = 3600;
        bytes32 receiver = bytes32(uint256(uint160(makeAddr("receiver"))));

        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.SetRateLimit,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                rateMax,
                window
            )
        );

        // Authorize a large transfer for `investor` only
        _fromHub(
            abi.encode(
                IBridgeCircuitBreaker.ConfigKind.AuthorizeTransfer,
                ShareClassId.unwrap(SC_1),
                LOCAL_CENTRIFUGE_ID,
                TARGET,
                bytes32(bytes20(investor)),
                receiver,
                AMOUNT
            )
        );

        // `investor2` cannot consume `investor`'s authorization despite matching receiver/amount
        vm.prank(investor2);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor2, investor2, AMOUNT, 0, 0, investor2);
        assertEq(shareToken.balanceOf(investor2), AMOUNT);

        // The authorized sender still goes through
        vm.prank(investor);
        spoke.crosschainTransferShares(TARGET, POOL_A, SC_1, receiver, investor, investor, AMOUNT, 0, 0, investor);
        assertEq(shareToken.balanceOf(investor), 2 * AMOUNT);
    }
}
