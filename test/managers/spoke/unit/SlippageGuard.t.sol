// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18} from "../../../../src/misc/types/D18.sol";
import {IERC6909MetadataExt} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {SlippageGuard} from "../../../../src/managers/spoke/guards/SlippageGuard.sol";
import {ISlippageGuard, AssetEntry} from "../../../../src/managers/spoke/guards/interfaces/ISlippageGuard.sol";

import "forge-std/Test.sol";

contract SlippageGuardTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    AssetId constant ASSET_ID_1 = AssetId.wrap(1);
    AssetId constant ASSET_ID_2 = AssetId.wrap(2);
    AssetId constant ASSET_ID_3 = AssetId.wrap(3);

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

// --- Opener check ---

contract SlippageGuardOpenerTest is SlippageGuardTest {
    function testCloseFromDifferentCallerReverts() public {
        _mockBalance(assetA, 0, 1000e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        vm.expectRevert(ISlippageGuard.NotOpener.selector);
        vm.prank(makeAddr("attacker"));
        guard.close(POOL_A, SC_1, 100);
    }

    function testCloseFromSameCallerSucceeds() public {
        _mockBalance(assetA, 0, 1000e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));
        guard.close(POOL_A, SC_1, 100);
    }

    function testCloseWithDifferentPoolIdReverts() public {
        _mockBalance(assetA, 0, 1000e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        vm.expectRevert(ISlippageGuard.ContextMismatch.selector);
        guard.close(PoolId.wrap(99), SC_1, 100);
    }

    function testCloseWithDifferentShareClassReverts() public {
        _mockBalance(assetA, 0, 1000e18);
        guard.open(POOL_A, SC_1, _singleAssetEntries(assetA));

        vm.expectRevert(ISlippageGuard.ContextMismatch.selector);
        guard.close(POOL_A, ShareClassId.wrap(bytes16("other")), 100);
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
        uint128 maxPeriodLoss = 500e18;
        uint32 periodDuration = 1 days;

        vm.expectEmit();
        emit ISlippageGuard.SetConfig(POOL_A, SC_1, maxPeriodLoss, periodDuration);

        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(maxPeriodLoss, periodDuration));

        (uint128 storedLoss, uint32 storedDuration) = guard.config(POOL_A, SC_1);
        assertEq(storedLoss, maxPeriodLoss);
        assertEq(storedDuration, periodDuration);
    }

    function testSetConfigNotAuthorized() public {
        vm.expectRevert(ISlippageGuard.NotAuthorized.selector);
        vm.prank(makeAddr("random"));
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint128(500e18), uint32(1 days)));
    }

    function testSetConfigOverwrite() public {
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint128(500e18), uint32(1 days)));

        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint128(200e18), uint32(2 days)));

        (uint128 storedLoss, uint32 storedDuration) = guard.config(POOL_A, SC_1);
        assertEq(storedLoss, 200e18);
        assertEq(storedDuration, 2 days);
    }
}

// --- Period-based cumulative loss ---

contract SlippageGuardPeriodLossTest is SlippageGuardTest {
    // Max allowed cumulative loss per period: 500e18 pool units
    uint128 constant MAX_PERIOD_LOSS = 500e18;

    function setUp() public override {
        super.setUp();

        // Configure period: 500e18 max loss over 1 day
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(MAX_PERIOD_LOSS, uint32(1 days)));
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

        // Script 1: loss = 10e18 pool units (within 500e18 limit)
        _doSwapWithLoss(1000e18, 990e18);

        (uint128 loss, uint48 start) = guard.period(POOL_A, SC_1);
        assertEq(loss, 10e18);
        assertEq(start, uint48(block.timestamp));

        // Script 2: another 9.9e18 loss (cumulative 19.9e18, well within 500e18)
        _doSwapWithLoss(990e18, 980.1e18);
    }

    function testCumulativeLossExceedsBounds() public {
        // Script 1: loss = 300e18 (within 500e18 limit)
        _doSwapWithLoss(1000e18, 700e18);

        // Script 2: loss = 210e18 — cumulative 510e18 > 500e18 limit
        _mockBalance(assetA, 0, 700e18);
        _mockBalance(assetB, 0, 0);

        guard.open(POOL_A, SC_1, _twoAssetEntries(assetA, assetB));

        _mockBalance(assetA, 0, 0);
        _mockBalance(assetB, 0, 490e18);

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 10_000);
    }

    function testPeriodResetsAfterDuration() public {
        // Script 1: loss = 400e18 (within 500e18)
        _doSwapWithLoss(1000e18, 600e18);

        (uint128 lossBefore,) = guard.period(POOL_A, SC_1);
        assertEq(lossBefore, 400e18);

        // Warp past period duration
        vm.warp(block.timestamp + 1 days + 1);

        // Script 2: loss = 400e18 again — period resets, so this starts fresh
        _doSwapWithLoss(600e18, 200e18);

        (uint128 lossAfter, uint48 newStart) = guard.period(POOL_A, SC_1);
        // After reset, loss should be just the new script's loss (not accumulated)
        assertEq(lossAfter, 400e18);
        assertEq(newStart, uint48(block.timestamp));
    }

    function testPeriodDisabledWhenZeroDuration() public {
        // Override config with zero duration (disabled)
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint128(500e18), uint32(0)));

        // Even with large loss, no PeriodLossExceeded because tracking is disabled
        _doSwapWithLoss(1000e18, 900e18);

        // Second script with large loss — still no revert
        _doSwapWithLoss(900e18, 810e18);
    }
}

// --- ERC-6909 asset support ---

contract SlippageGuardERC6909Test is SlippageGuardTest {
    address erc6909 = makeAddr("erc6909");
    uint256 erc6909TokenId = 42;

    function setUp() public override {
        super.setUp();

        // Mock ERC6909 decimals (non-zero tokenId branch)
        vm.mockCall(
            erc6909,
            abi.encodeWithSelector(IERC6909MetadataExt.decimals.selector, erc6909TokenId),
            abi.encode(uint8(18))
        );
        vm.mockCall(
            spoke, abi.encodeWithSelector(ISpoke.assetToId.selector, erc6909, erc6909TokenId), abi.encode(ASSET_ID_3)
        );
        vm.mockCall(
            spoke,
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID_3, true),
            abi.encode(PRICE_ONE)
        );
    }

    function _erc6909Entry() internal view returns (AssetEntry[] memory) {
        AssetEntry[] memory entries = new AssetEntry[](1);
        entries[0] = AssetEntry(erc6909, erc6909TokenId);
        return entries;
    }

    function _mixedEntries() internal view returns (AssetEntry[] memory) {
        AssetEntry[] memory entries = new AssetEntry[](2);
        entries[0] = AssetEntry(assetA, 0);
        entries[1] = AssetEntry(erc6909, erc6909TokenId);
        return entries;
    }

    function testERC6909NoValueChange() public {
        _mockBalance(erc6909, erc6909TokenId, 1000e18);

        guard.open(POOL_A, SC_1, _erc6909Entry());

        guard.close(POOL_A, SC_1, 100);
    }

    function testERC6909WithdrawalWithinBounds() public {
        _mockBalance(erc6909, erc6909TokenId, 1000e18);
        _mockBalance(assetA, 0, 0);

        guard.open(POOL_A, SC_1, _mixedEntries());

        // Swap: withdraw 200 ERC6909, deposit 195 assetA (2.5% slippage, bound = 500 bps)
        _mockBalance(erc6909, erc6909TokenId, 800e18);
        _mockBalance(assetA, 0, 195e18);

        guard.close(POOL_A, SC_1, 500);
    }

    function testERC6909WithdrawalExceedsBounds() public {
        _mockBalance(erc6909, erc6909TokenId, 1000e18);
        _mockBalance(assetA, 0, 0);

        guard.open(POOL_A, SC_1, _mixedEntries());

        // Swap: withdraw 200 ERC6909, deposit 150 assetA (25% slippage, bound = 500 bps)
        _mockBalance(erc6909, erc6909TokenId, 800e18);
        _mockBalance(assetA, 0, 150e18);

        vm.expectRevert();
        guard.close(POOL_A, SC_1, 500);
    }

    function testERC6909DepositOnly() public {
        _mockBalance(erc6909, erc6909TokenId, 100e18);

        guard.open(POOL_A, SC_1, _erc6909Entry());

        _mockBalance(erc6909, erc6909TokenId, 200e18);

        guard.close(POOL_A, SC_1, 0);
    }

    function testERC6909DifferentDecimals() public {
        // 6-decimal ERC6909 at 2:1 price (each token worth 2 pool units)
        uint8 erc6909Decimals = 6;
        D18 priceTwo = D18.wrap(2e18);

        vm.mockCall(
            erc6909,
            abi.encodeWithSelector(IERC6909MetadataExt.decimals.selector, erc6909TokenId),
            abi.encode(erc6909Decimals)
        );
        vm.mockCall(
            spoke,
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID_3, true),
            abi.encode(priceTwo)
        );

        // Pre: 1000e6 erc6909 (worth 2000e18 pool units) + 0 assetA
        _mockBalance(erc6909, erc6909TokenId, 1000e6);
        _mockBalance(assetA, 0, 0);

        guard.open(POOL_A, SC_1, _mixedEntries());

        // Post: 500e6 erc6909 (withdrew 500e6 → 1000e18 pool units) + 960e18 assetA (deposited 960e18 pool units)
        // loss = 1000e18 - 960e18 = 40e18, 40/1000 = 4% < 5%
        _mockBalance(erc6909, erc6909TokenId, 500e6);
        _mockBalance(assetA, 0, 960e18);

        guard.close(POOL_A, SC_1, 500);
    }

    function testERC6909PeriodLossTracking() public {
        vm.prank(contractUpdater);
        guard.trustedCall(POOL_A, SC_1, abi.encode(uint128(500e18), uint32(1 days)));

        // Script with ERC6909 loss
        _mockBalance(erc6909, erc6909TokenId, 1000e18);
        _mockBalance(assetA, 0, 0);

        guard.open(POOL_A, SC_1, _mixedEntries());

        _mockBalance(erc6909, erc6909TokenId, 0);
        _mockBalance(assetA, 0, 990e18);

        guard.close(POOL_A, SC_1, 10_000);

        (uint128 loss,) = guard.period(POOL_A, SC_1);
        assertEq(loss, 10e18);
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
