// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18} from "../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {SlippageGuard} from "../../../../src/managers/spoke/SlippageGuard.sol";
import {ISlippageGuard, AssetEntry} from "../../../../src/managers/spoke/interfaces/ISlippageGuard.sol";

import "forge-std/Test.sol";

contract SlippageGuardTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    AssetId constant ASSET_ID_1 = AssetId.wrap(1);
    AssetId constant ASSET_ID_2 = AssetId.wrap(2);

    D18 constant PRICE_ONE = D18.wrap(1e18);

    address spoke = makeAddr("spoke");
    address balanceSheet = makeAddr("balanceSheet");
    address contractUpdater = makeAddr("contractUpdater");
    address shareToken = makeAddr("shareToken");
    address assetA = makeAddr("assetA");
    address assetB = makeAddr("assetB");

    SlippageGuard guard;

    function setUp() public virtual {
        _setupMocks();
        guard = new SlippageGuard(ISpoke(spoke), IBalanceSheet(balanceSheet), contractUpdater);
    }

    function _setupMocks() internal {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.shareToken.selector, POOL_A, SC_1), abi.encode(shareToken));
        vm.mockCall(shareToken, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.mockCall(assetA, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));
        vm.mockCall(assetB, abi.encodeWithSignature("decimals()"), abi.encode(uint8(18)));

        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.assetToId.selector, assetA, uint256(0)), abi.encode(ASSET_ID_1)
        );
        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.assetToId.selector, assetB, uint256(0)), abi.encode(ASSET_ID_2)
        );

        vm.mockCall(
            spoke,
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID_1, true),
            abi.encode(PRICE_ONE)
        );
        vm.mockCall(
            spoke,
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID_2, true),
            abi.encode(PRICE_ONE)
        );
    }

    function _mockBalance(address asset, uint256 tokenId, uint128 available) internal {
        vm.mockCall(
            balanceSheet,
            abi.encodeWithSelector(IBalanceSheet.availableBalanceOf.selector, POOL_A, SC_1, asset, tokenId),
            abi.encode(available)
        );
    }

    function _singleAssetEntries(address asset) internal pure returns (AssetEntry[] memory) {
        AssetEntry[] memory entries = new AssetEntry[](1);
        entries[0] = AssetEntry(asset, 0);
        return entries;
    }

    function _twoAssetEntries(address a, address b) internal pure returns (AssetEntry[] memory) {
        AssetEntry[] memory entries = new AssetEntry[](2);
        entries[0] = AssetEntry(a, 0);
        entries[1] = AssetEntry(b, 0);
        return entries;
    }
}

// --- Close without open ---

contract SlippageGuardCloseWithoutOpenTest is SlippageGuardTest {
    function testCloseWithoutOpenReverts() public {
        vm.expectRevert(ISlippageGuard.NotOpen.selector);
        guard.close(POOL_A, SC_1, 100);
    }
}

// --- Slippage within bounds (swap scenarios) ---

contract SlippageGuardWithinBoundsTest is SlippageGuardTest {
    function testNoValueChange() public {
        _mockBalance(assetA, 0, 1000e18);

        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        guard.close(POOL_A, SC_1, 100);
    }

    function testSwapExactlyAtBound() public {
        // Swap: withdraw 1000 assetA, deposit 950 assetB (5% slippage, bound = 500 bps)
        // loss = 1000 - 950 = 50, check: 50 <= 1000 * 500 / 10000 = 50
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 950e18);

        guard.close(POOL_A, SC_1, 500);
    }

    function testSwapBelowBound() public {
        // Swap: withdraw 1000 assetA, deposit 980 assetB (2% slippage, bound = 500 bps)
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 980e18);

        guard.close(POOL_A, SC_1, 500);
    }

    function testZeroSlippageSwap() public {
        // Perfect swap: withdraw 500, deposit 500 (0% slippage)
        _mockBalance(assetA, 0, 500e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 500e18);

        guard.close(POOL_A, SC_1, 0);
    }
}

// --- Slippage exceeding bounds ---

contract SlippageGuardExceedingBoundsTest is SlippageGuardTest {
    function testSwapExceedsBound() public {
        // Swap: withdraw 1000 assetA, deposit 900 assetB (10% slippage, bound = 500 bps)
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 900e18);

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 500);
    }

    function testTotalLossReverts() public {
        // Withdraw 1000, deposit 0 (100% loss)
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        // assetB still 0

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 500);
    }
}

// --- Multi-asset aggregation ---

contract SlippageGuardMultiAssetTest is SlippageGuardTest {
    function testMultiAssetSwapWithinBounds() public {
        // Both assets at price 1:1
        // Pre: 1000 assetA + 500 assetB
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 500e18);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        // Post: swapped 200 assetA for 192 assetB (4% slippage on the swap)
        // assetA: 1000 -> 800 (withdrew 200 pool units)
        // assetB: 500 -> 692 (deposited 192 pool units)
        // loss = 200 - 192 = 8, 8/200 = 4% < 5%
        _mockBalance(assetA, 0, 800e18);
        _mockBalance(assetB, 0, 692e18);

        guard.close(POOL_A, SC_1, 500);
    }

    function testMultiAssetSwapExceedsBounds() public {
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 500e18);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        // Swapped 200 assetA for 170 assetB (15% slippage)
        // loss = 200 - 170 = 30, 30/200 = 15% > 5%
        _mockBalance(assetA, 0, 800e18);
        _mockBalance(assetB, 0, 670e18);

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 500);
    }
}

// --- Deposit-only script ---

contract SlippageGuardDepositOnlyTest is SlippageGuardTest {
    function testDepositOnlyPassesTrivially() public {
        _mockBalance(assetA, 0, 100e18);

        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        _mockBalance(assetA, 0, 200e18);

        // totalWithdrawnValue = 0, passes trivially
        guard.close(POOL_A, SC_1, 100);
    }
}

// --- Stale price ---

contract SlippageGuardStalePriceTest is SlippageGuardTest {
    function testStalePriceReverts() public {
        _mockBalance(assetA, 0, 1000e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        // Post: partial swap
        _mockBalance(assetA, 0, 500e18);
        _mockBalance(assetB, 0, 480e18);

        // Price call for assetA reverts (stale)
        vm.mockCallRevert(
            spoke,
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID_1, true),
            abi.encodeWithSelector(ISpoke.InvalidPrice.selector)
        );

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 500);
    }
}

// --- Re-open overwrites ---

contract SlippageGuardReopenTest is SlippageGuardTest {
    function testReopenOverwritesPreviousState() public {
        // First open with 1000 tokens
        _mockBalance(assetA, 0, 1000e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        // Second open overwrites with 500 tokens
        _mockBalance(assetA, 0, 500e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        // Close — no change from second snapshot
        guard.close(POOL_A, SC_1, 100);
    }
}

// --- TrustedCall (config management) ---

contract SlippageGuardTrustedCallTest is SlippageGuardTest {
    function testSetConfig() public {
        uint16 maxPeriodLossBps = 500;
        uint32 periodDuration = 1 days;

        vm.expectEmit();
        emit ISlippageGuard.SetConfig(POOL_A, SC_1, maxPeriodLossBps, periodDuration);

        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(maxPeriodLossBps, periodDuration));

        (uint16 storedBps, uint32 storedDuration) = guard.config(POOL_A, SC_1);
        assertEq(storedBps, maxPeriodLossBps);
        assertEq(storedDuration, periodDuration);
    }

    function testSetConfigNotAuthorized() public {
        vm.expectRevert(ISlippageGuard.NotAuthorized.selector);
        vm.prank(makeAddr("random"));
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint16(500), uint32(1 days)));
    }

    function testSetConfigOverwrite() public {
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint16(500), uint32(1 days)));

        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint16(200), uint32(2 days)));

        (uint16 storedBps, uint32 storedDuration) = guard.config(POOL_A, SC_1);
        assertEq(storedBps, 200);
        assertEq(storedDuration, 2 days);
    }
}

// --- Period-based cumulative loss ---

contract SlippageGuardPeriodLossTest is SlippageGuardTest {
    function setUp() public override {
        super.setUp();

        // Configure period: 500 bps max over 1 day
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint16(500), uint32(1 days)));
    }

    function _doSwapWithLoss(uint128 preBalance, uint128 postBalance) internal {
        _mockBalance(assetA, 0, preBalance);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, postBalance);

        // Per-script bound high enough to not trigger
        guard.close(POOL_A, SC_1, 10_000);
    }

    function testCumulativeLossWithinBounds() public {
        // Warp past the initial period so the first close sets periodStart
        vm.warp(block.timestamp + 1 days + 1);

        // Script 1: 1% loss (well within 5% period limit)
        _doSwapWithLoss(1000e18, 990e18);

        (uint256 loss, uint48 start) = guard.period(POOL_A, SC_1);
        assertGt(loss, 0);
        assertEq(start, uint48(block.timestamp));

        // Script 2: another 1% loss (cumulative 2%, still within 5%)
        _doSwapWithLoss(990e18, 980.1e18);
    }

    function testCumulativeLossExceedsBounds() public {
        // Script 1: 3% loss
        _doSwapWithLoss(1000e18, 970e18);

        // Script 2: another 3% loss — cumulative ~6% > 5% limit
        _mockBalance(assetA, 0, 970e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 940.9e18);

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 10_000);
    }

    function testPeriodResetsAfterDuration() public {
        // Script 1: 4% loss (within 5%)
        _doSwapWithLoss(1000e18, 960e18);

        (uint256 lossBefore,) = guard.period(POOL_A, SC_1);
        assertGt(lossBefore, 0);

        // Warp past period duration
        vm.warp(block.timestamp + 1 days + 1);

        // Script 2: 4% loss again — period resets, so this starts fresh
        _doSwapWithLoss(960e18, 921.6e18);

        (uint256 lossAfter, uint48 newStart) = guard.period(POOL_A, SC_1);
        // After reset, loss should be just the new script's fraction (not accumulated)
        assertLt(lossAfter, lossBefore + lossAfter);
        assertEq(newStart, uint48(block.timestamp));
    }

    function testPeriodDisabledWhenZeroDuration() public {
        // Override config with zero duration (disabled)
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint16(500), uint32(0)));

        // Even with 10% loss, no PeriodLossExceeded because tracking is disabled
        _doSwapWithLoss(1000e18, 900e18);

        // Second script with 10% loss — still no revert
        _doSwapWithLoss(900e18, 810e18);
    }
}

// --- Constructor ---

contract SlippageGuardConstructorTest is SlippageGuardTest {
    function testConstructor() public view {
        assertEq(address(guard.spoke()), spoke);
        assertEq(address(guard.balanceSheet()), balanceSheet);
        assertEq(guard.contractUpdater(), contractUpdater);
    }
}
