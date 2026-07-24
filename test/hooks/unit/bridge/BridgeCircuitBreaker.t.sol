// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {BridgeSharesParams, BridgeSharesResult} from "../../../../src/core/hub/interfaces/IBridgingHook.sol";

import {BridgeCircuitBreaker} from "../../../../src/hooks/bridge/BridgeCircuitBreaker.sol";
import {IBridgeCircuitBreaker} from "../../../../src/hooks/bridge/interfaces/IBridgeCircuitBreaker.sol";

import "forge-std/Test.sol";

contract MockCircuitBreakerGuard {
    error ExceedsCumulativeLimit(bytes32 key, uint256 amount, uint256 max, uint256 window);

    bool public shouldRevert;
    bytes32 public lastKey;
    uint256 public lastAmount;
    uint256 public lastMax;
    uint256 public lastWindow;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function tally(bytes32 key, uint256 amount, uint256 max, uint256 window) external {
        lastKey = key;
        lastAmount = amount;
        lastMax = max;
        lastWindow = window;
        if (shouldRevert || amount > max) revert ExceedsCumulativeLimit(key, amount, max, window);
    }
}

contract BridgeCircuitBreakerTestBase is Test {
    address immutable HUB_HANDLER = makeAddr("hubHandler");
    address immutable ENVOY = makeAddr("envoy");

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    uint16 constant ORIGIN = 1;
    uint16 constant TARGET = 2;
    uint128 constant AMOUNT = 1000e18;

    BridgeCircuitBreaker hook;
    MockCircuitBreakerGuard guard;

    BridgeSharesParams internal baseParams;

    function setUp() public virtual {
        guard = new MockCircuitBreakerGuard();
        hook = new BridgeCircuitBreaker(ENVOY, address(guard), address(this));
        hook.rely(HUB_HANDLER);

        baseParams = BridgeSharesParams({
            originCentrifugeId: ORIGIN,
            targetCentrifugeId: TARGET,
            poolId: POOL_A,
            scId: SC_1,
            sender: bytes32(0),
            receiver: bytes32(uint256(uint160(makeAddr("receiver")))),
            amount: AMOUNT,
            extraGasLimit: 0,
            refund: makeAddr("refund")
        });
    }

    function _fromHub(bytes memory payload) internal {
        vm.prank(ENVOY);
        hook.fromHub(POOL_A, payload);
    }

    function _setPaused(ShareClassId scId, bool isPaused) internal {
        _fromHub(abi.encode(uint8(0), ShareClassId.unwrap(scId), isPaused));
    }

    function _setRateLimit(ShareClassId scId, uint16 centrifugeId, uint128 max, uint32 window) internal {
        _fromHub(abi.encode(uint8(1), ShareClassId.unwrap(scId), centrifugeId, max, window));
    }

    function _transfer() internal returns (BridgeSharesResult memory) {
        vm.prank(HUB_HANDLER);
        return hook.onBridgeShares(baseParams);
    }
}

contract BridgeCircuitBreakerTestConstructor is BridgeCircuitBreakerTestBase {
    function testConstructor() public view {
        assertEq(hook.wards(HUB_HANDLER), 1);
        assertEq(hook.envoy(), ENVOY);
        assertEq(address(hook.circuitBreakerGuard()), address(guard));
    }
}

contract BridgeCircuitBreakerTestPause is BridgeCircuitBreakerTestBase {
    function setUp() public override {
        super.setUp();
        _setRateLimit(SC_1, ORIGIN, type(uint128).max, 3600);
    }

    function testPassThrough() public {
        BridgeSharesResult memory result = _transfer();
        assertEq(uint256(result.amount), uint256(AMOUNT));
        assertEq(result.receiver, baseParams.receiver);
        assertEq(result.refund, baseParams.refund);
        assertEq(uint256(result.extraGasLimit), uint256(baseParams.extraGasLimit));
    }

    function testErrNotWard(address notWard) public {
        vm.assume(notWard != HUB_HANDLER && notWard != address(this));
        vm.prank(notWard);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        hook.onBridgeShares(baseParams);
    }

    function testErrPaused() public {
        _setPaused(SC_1, true);
        vm.expectRevert(IBridgeCircuitBreaker.Paused.selector);
        _transfer();
    }

    function testUnpause() public {
        _setPaused(SC_1, true);
        _setPaused(SC_1, false);
        BridgeSharesResult memory result = _transfer();
        assertEq(uint256(result.amount), uint256(AMOUNT));
    }

    function testPausedIsPoolAndScSpecific() public {
        ShareClassId SC_2 = ShareClassId.wrap(bytes16("sc2"));
        _setPaused(SC_1, true);
        assertFalse(hook.paused(POOL_A, SC_2));
    }

    function testSetPausedEmitsEvent() public {
        vm.prank(ENVOY);
        vm.expectEmit();
        emit IBridgeCircuitBreaker.SetPaused(POOL_A, SC_1, true);
        hook.fromHub(POOL_A, abi.encode(uint8(0), ShareClassId.unwrap(SC_1), true));
        assertTrue(hook.paused(POOL_A, SC_1));
    }
}

contract BridgeCircuitBreakerTestRateLimit is BridgeCircuitBreakerTestBase {
    function testDefaultRateMaxBlocksTransfer() public {
        vm.prank(HUB_HANDLER);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        hook.onBridgeShares(baseParams);
    }

    function testCallsTallyWhenLimitSet() public {
        uint128 max = 5000e18;
        uint32 window = 3600;
        _setRateLimit(SC_1, ORIGIN, max, window);

        _transfer();

        bytes32 expectedKey = keccak256(abi.encode(POOL_A, SC_1, ORIGIN));
        assertEq(guard.lastKey(), expectedKey);
        assertEq(guard.lastAmount(), uint256(AMOUNT));
        assertEq(guard.lastMax(), uint256(max));
        assertEq(guard.lastWindow(), uint256(window));
    }

    function testRevertsWhenGuardReverts() public {
        uint128 max = AMOUNT + 1; // amount <= max so tally is called
        uint32 window = 3600;
        _setRateLimit(SC_1, ORIGIN, max, window);
        guard.setShouldRevert(true);

        vm.prank(HUB_HANDLER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCircuitBreakerGuard.ExceedsCumulativeLimit.selector,
                keccak256(abi.encode(POOL_A, SC_1, ORIGIN)),
                AMOUNT,
                max,
                uint256(window)
            )
        );
        hook.onBridgeShares(baseParams);
    }

    function testRateLimitIsChainSpecific() public {
        uint128 max = 1000e18;
        uint32 window = 3600;
        _setRateLimit(SC_1, ORIGIN, max, window);

        (uint128 storedMax,) = hook.limits(POOL_A, SC_1, ORIGIN);
        (uint128 otherMax,) = hook.limits(POOL_A, SC_1, uint16(3));
        assertEq(uint256(storedMax), uint256(max));
        assertEq(uint256(otherMax), uint256(0));
    }

    function testZeroRateMaxBlocksTransfers() public {
        _setRateLimit(SC_1, ORIGIN, 1000e18, 3600);
        _setRateLimit(SC_1, ORIGIN, 0, 3600);

        vm.prank(HUB_HANDLER);
        vm.expectRevert(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
        hook.onBridgeShares(baseParams);
    }

    function testSetRateLimitEmitsEvent() public {
        uint128 max = 10000e18;
        uint32 window = 86400;
        vm.prank(ENVOY);
        vm.expectEmit();
        emit IBridgeCircuitBreaker.SetRateLimit(POOL_A, SC_1, TARGET, max, window);
        hook.fromHub(POOL_A, abi.encode(uint8(1), ShareClassId.unwrap(SC_1), TARGET, max, window));

        (uint128 storedMax, uint32 storedWindow) = hook.limits(POOL_A, SC_1, TARGET);
        assertEq(uint256(storedMax), uint256(max));
        assertEq(uint256(storedWindow), uint256(window));
    }
}

contract BridgeCircuitBreakerTestFromHub is BridgeCircuitBreakerTestBase {
    function testErrUnknownConfigKind() public {
        vm.prank(ENVOY);
        vm.expectRevert(IBridgeCircuitBreaker.UnknownConfigKind.selector);
        hook.fromHub(POOL_A, abi.encode(uint8(4), ShareClassId.unwrap(SC_1), true));
    }
}

contract BridgeCircuitBreakerTestAuthorizeTransfer is BridgeCircuitBreakerTestBase {
    uint128 constant RATE_MAX = AMOUNT / 2; // AMOUNT always exceeds this

    bytes32 internal authKey;
    bytes internal guardRevert; // TransferNotAuthorized for AMOUNT vs RATE_MAX (amount exceeds rateMax)

    function setUp() public override {
        super.setUp();
        _setRateLimit(SC_1, ORIGIN, RATE_MAX, 3600);
        authKey = keccak256(abi.encode(POOL_A, SC_1, ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT));
        guardRevert = abi.encodeWithSelector(IBridgeCircuitBreaker.TransferNotAuthorized.selector);
    }

    function _authorizeTransfer() internal {
        _fromHub(
            abi.encode(
                uint8(2), ShareClassId.unwrap(SC_1), ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
            )
        );
    }

    function _cancelAuthorizations() internal {
        _fromHub(
            abi.encode(
                uint8(3), ShareClassId.unwrap(SC_1), ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
            )
        );
    }

    function testRevertsWhenNotAuthorized() public {
        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(baseParams);
    }

    function testAuthorizeAllowsLargeTransfer() public {
        _authorizeTransfer();
        assertEq(hook.authorizations(authKey), 1);

        BridgeSharesResult memory result = _transfer();
        assertEq(uint256(result.amount), uint256(AMOUNT));
        assertEq(hook.authorizations(authKey), 0);
    }

    function testAuthorizationIsConsumedOnUse() public {
        _authorizeTransfer();
        _transfer();

        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(baseParams);
    }

    function testMultipleAuthorizationsAllowMultipleTransfers() public {
        _authorizeTransfer();
        _authorizeTransfer();
        _authorizeTransfer();
        assertEq(hook.authorizations(authKey), 3);

        _transfer();
        assertEq(hook.authorizations(authKey), 2);
        _transfer();
        assertEq(hook.authorizations(authKey), 1);
        _transfer();
        assertEq(hook.authorizations(authKey), 0);

        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(baseParams);
    }

    function testCancelAuthorizationsResetsCounter() public {
        _authorizeTransfer();
        _authorizeTransfer();
        assertEq(hook.authorizations(authKey), 2);

        _cancelAuthorizations();
        assertEq(hook.authorizations(authKey), 0);

        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(baseParams);
    }

    function testCancelAuthorizationsEmitsEvent() public {
        vm.prank(ENVOY);
        vm.expectEmit();
        emit IBridgeCircuitBreaker.CancelTransferAuthorizations(
            POOL_A, SC_1, ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
        );
        hook.fromHub(
            POOL_A,
            abi.encode(
                uint8(3), ShareClassId.unwrap(SC_1), ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
            )
        );
    }

    function testAuthorizeTransferEmitsEvent() public {
        vm.prank(ENVOY);
        vm.expectEmit();
        emit IBridgeCircuitBreaker.AuthorizeTransfer(
            POOL_A, SC_1, ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
        );
        hook.fromHub(
            POOL_A,
            abi.encode(
                uint8(2), ShareClassId.unwrap(SC_1), ORIGIN, TARGET, baseParams.sender, baseParams.receiver, AMOUNT
            )
        );
    }

    function testBelowRateMaxTransferBlockedByWindowCanBeAuthorized() public {
        // Use an amount at or below rateMax so it normally goes through tally, not the auth check
        uint128 smallAmount = RATE_MAX;
        baseParams.amount = smallAmount;

        // Simulate the cumulative window being full via the guard
        guard.setShouldRevert(true);

        // Without authorization: blocked by the guard (cumulative window exceeded)
        vm.prank(HUB_HANDLER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCircuitBreakerGuard.ExceedsCumulativeLimit.selector,
                keccak256(abi.encode(POOL_A, SC_1, ORIGIN)),
                uint256(smallAmount),
                uint256(RATE_MAX),
                uint256(3600)
            )
        );
        hook.onBridgeShares(baseParams);

        // Manager authorizes this exact transfer
        bytes32 smallKey =
            keccak256(abi.encode(POOL_A, SC_1, ORIGIN, TARGET, baseParams.sender, baseParams.receiver, smallAmount));
        _fromHub(
            abi.encode(
                uint8(2), ShareClassId.unwrap(SC_1), ORIGIN, TARGET, baseParams.sender, baseParams.receiver, smallAmount
            )
        );
        assertEq(hook.authorizations(smallKey), 1);

        // With authorization: bypasses tally entirely, succeeds even though window is full
        vm.prank(HUB_HANDLER);
        BridgeSharesResult memory result = hook.onBridgeShares(baseParams);
        assertEq(uint256(result.amount), uint256(smallAmount));
        assertEq(hook.authorizations(smallKey), 0);
    }

    function testAuthorizationCannotBeConsumedOnDifferentDestination() public {
        _authorizeTransfer();

        // Attempt to consume that authorization for a transfer to a different destination (chain 3)
        uint16 otherTarget = 3;
        BridgeSharesParams memory otherParams = baseParams;
        otherParams.targetCentrifugeId = otherTarget;

        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(otherParams);

        assertEq(hook.authorizations(authKey), 1);
    }

    function testAuthorizationIsKeyedByTransferIdentity() public {
        // Authorization for a different receiver does not apply
        _authorizeTransfer();

        BridgeSharesParams memory otherParams = baseParams;
        otherParams.receiver = bytes32(uint256(uint160(makeAddr("otherReceiver"))));

        vm.prank(HUB_HANDLER);
        vm.expectRevert(guardRevert);
        hook.onBridgeShares(otherParams);
    }

    function testLargeTransferDoesNotTallyAgainstRateLimit() public {
        _authorizeTransfer();
        _transfer();

        assertEq(guard.lastAmount(), 0); // tally never called for large transfers
    }

    function testSmallTransferStillTalliesNormally() public {
        uint128 smallAmount = RATE_MAX;
        baseParams.amount = smallAmount;
        _transfer();

        assertEq(guard.lastAmount(), uint256(smallAmount));
    }
}
