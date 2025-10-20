// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC20Metadata} from "../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {VaultDetails, IVaultRegistry} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";

import {SyncManager} from "../../../src/vaults/SyncManager.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import "forge-std/Test.sol";

contract IsContract {}

abstract contract SyncManagerBaseTest is Test {
    using CastLib for *;

    address immutable AUTH = makeAddr("AUTH");
    address immutable USER = makeAddr("USER");

    ISpoke spoke = ISpoke(address(new IsContract()));
    IBalanceSheet balanceSheet = IBalanceSheet(address(new IsContract()));
    IVaultRegistry vaultRegistry = IVaultRegistry(address(new IsContract()));
    IShareToken shareToken = IShareToken(address(new IsContract()));
    IBaseVault vault = IBaseVault(address(new IsContract()));

    address asset = address(new IsContract());

    PoolId constant POOL_ID = PoolId.wrap(1);
    ShareClassId constant SC_ID = ShareClassId.wrap(bytes16("sc1"));
    AssetId constant ASSET_ID = AssetId.wrap(1);
    uint256 constant TOKEN_ID = 0;

    SyncManager syncManager;

    function setUp() public virtual {
        syncManager = new SyncManager(AUTH);

        vm.startPrank(AUTH);
        syncManager.file("spoke", address(spoke));
        syncManager.file("vaultRegistry", address(vaultRegistry));
        syncManager.file("balanceSheet", address(balanceSheet));
        vm.stopPrank();

        vm.mockCall(address(vault), abi.encodeWithSignature("poolId()"), abi.encode(POOL_ID));
        vm.mockCall(address(vault), abi.encodeWithSignature("scId()"), abi.encode(SC_ID));
        vm.mockCall(address(vault), abi.encodeWithSignature("share()"), abi.encode(address(shareToken)));
    }

    //----------------------------------------------------------------------------------------------
    // Helper functions
    //----------------------------------------------------------------------------------------------

    function _setupVaultDetails(uint8 assetDecimals, uint8 shareDecimals) internal {
        VaultDetails memory details = VaultDetails({assetId: ASSET_ID, asset: asset, tokenId: TOKEN_ID, isLinked: true});

        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(IVaultRegistry.vaultDetails.selector, vault),
            abi.encode(details)
        );

        vm.mockCall(address(asset), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(assetDecimals));

        vm.mockCall(
            address(shareToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(shareDecimals)
        );
    }

    function _setupPrices(D18 poolPerShare, D18 poolPerAsset) internal {
        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerShare.selector, POOL_ID, SC_ID, true),
            abi.encode(poolPerShare)
        );

        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(ISpoke.pricePoolPerAsset.selector, POOL_ID, SC_ID, ASSET_ID, true),
            abi.encode(poolPerAsset)
        );
    }

    function _setupMaxReserve(uint128 maxReserve_, uint128 availableBalance) internal {
        vm.startPrank(AUTH);
        syncManager.setMaxReserve(POOL_ID, SC_ID, asset, TOKEN_ID, maxReserve_);
        vm.stopPrank();

        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.availableBalanceOf.selector, POOL_ID, SC_ID, asset, TOKEN_ID),
            abi.encode(availableBalance)
        );
    }

    function _setupLinkedVault(bool isLinked) internal {
        vm.mockCall(
            address(vaultRegistry),
            abi.encodeWithSelector(IVaultRegistry.isLinked.selector, vault),
            abi.encode(isLinked)
        );
    }

    function _setupTransferRestriction(bool canTransfer) internal {
        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(IShareToken.checkTransferRestriction.selector),
            abi.encode(canTransfer)
        );
    }
}

/// @title SyncManagerMaxDepositMintEdgeCasesTest
/// @notice Tests edge cases: zero prices and overflow prevention for maxDeposit/maxMint
contract SyncManagerMaxDepositMintEdgeCasesTest is SyncManagerBaseTest {
    function testMaxDepositWithZeroPoolPerShare() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(0), d18(1, 1));
        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        assertEq(maxDeposit, 0, "maxDeposit should return 0 when poolPerShare is zero");
    }

    function testMaxMintWithZeroPoolPerShare() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(0), d18(1, 1));
        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);
        assertEq(maxMint, 0, "maxMint should return 0 when poolPerShare is zero");
    }

    function testMaxDepositWithZeroPoolPerAsset() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(0));
        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        assertEq(maxDeposit, 0, "maxDeposit should return 0 when poolPerAsset is zero");
    }

    function testMaxMintWithZeroPoolPerAsset() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(0));
        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);
        assertEq(maxMint, 0, "maxMint should return 0 when poolPerAsset is zero");
    }

    function testMaxDepositWithExtremeDecimalDifference() public {
        _setupVaultDetails(6, 18);

        D18 poolPerShare = d18(1, 1);
        D18 poolPerAsset = d18(5, 10);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        uint256 shares = syncManager.convertToShares(vault, maxDeposit);

        assertLe(shares, type(uint128).max, "Converted shares should not exceed uint128.max");
        assertTrue(maxDeposit > 0, "maxDeposit should be positive");
    }

    function testMaxMintWithExtremeDecimalDifference() public {
        _setupVaultDetails(6, 18);

        D18 poolPerShare = d18(1, 1);
        D18 poolPerAsset = d18(5, 10);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);

        assertLe(maxMint, type(uint128).max, "maxMint should not exceed uint128.max");
        assertTrue(maxMint > 0, "maxMint should be positive");
    }

    function testMaxDepositWithUnfavorablePriceRatio() public {
        _setupVaultDetails(18, 18);

        D18 poolPerShare = d18(1, 3);
        D18 poolPerAsset = d18(1, 1);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);

        uint256 shares = syncManager.convertToShares(vault, maxDeposit);
        assertLe(shares, type(uint128).max, "Should prevent uint128 overflow");
    }

    function testMaxMintWithUnfavorablePriceRatio() public {
        _setupVaultDetails(18, 18);

        D18 poolPerShare = d18(1, 3);
        D18 poolPerAsset = d18(1, 1);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);
        assertLe(maxMint, type(uint128).max, "maxMint should be within uint128");
    }
}

/// @title SyncManagerRestrictionsTest
/// @notice Tests all restriction scenarios: transfer hooks, vault linking, and reserve limits
contract SyncManagerRestrictionsTest is SyncManagerBaseTest {
    function testMaxDepositReturnsZeroWhenTransferBlocked() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(false);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        assertEq(maxDeposit, 0, "maxDeposit should return 0 when transfer is blocked");
    }

    function testMaxMintReturnsZeroWhenTransferBlocked() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(false);

        uint256 maxMint = syncManager.maxMint(vault, USER);
        assertEq(maxMint, 0, "maxMint should return 0 when transfer is blocked");
    }

    function testMaxDepositPassesCorrectShareAmountToHook() public {
        _setupVaultDetails(6, 18);

        D18 poolPerShare = d18(4, 1);
        D18 poolPerAsset = d18(2, 1);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(true);

        uint256 expectedAssets = 1000e6;
        uint256 expectedShares = syncManager.convertToShares(vault, expectedAssets);

        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(IShareToken.checkTransferRestriction.selector, address(0), USER, expectedShares),
            abi.encode(true)
        );

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        assertEq(maxDeposit, expectedAssets, "maxDeposit should pass shares to hook");
    }

    function testMaxMintPassesCorrectShareAmountToHook() public {
        _setupVaultDetails(6, 18);

        D18 poolPerShare = d18(4, 1);
        D18 poolPerAsset = d18(2, 1);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(true);

        uint256 expectedAssets = 1000e6;
        uint256 expectedShares = syncManager.convertToShares(vault, expectedAssets);

        vm.mockCall(
            address(shareToken),
            abi.encodeWithSelector(IShareToken.checkTransferRestriction.selector, address(0), USER, expectedShares),
            abi.encode(true)
        );

        uint256 maxMint = syncManager.maxMint(vault, USER);
        assertEq(maxMint, expectedShares, "maxMint should pass shares to hook");
    }

    function testMaxDepositWhenVaultUnlinked() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(false);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);

        assertEq(maxDeposit, 0, "maxDeposit should return 0 when vault is unlinked");
    }

    function testMaxMintWhenVaultUnlinked() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(false);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);

        assertEq(maxMint, 0, "maxMint should return 0 when vault is unlinked");
    }

    function testMaxDepositWithZeroMaxReserve() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(0, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);

        assertEq(maxDeposit, 0, "maxDeposit should return 0 when maxReserve is 0");
    }

    function testMaxMintWithZeroMaxReserve() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(0, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);

        assertEq(maxMint, 0, "maxMint should return 0 when maxReserve is 0");
    }

    function testMaxDepositWithMaxReserveExceeded() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(100e6, 500e6);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);

        assertEq(maxDeposit, 0, "maxDeposit should return 0 when reserve is exceeded");
    }

    function testMaxMintWithMaxReserveExceeded() public {
        _setupVaultDetails(6, 18);
        _setupPrices(d18(1, 1), d18(1, 1));
        _setupMaxReserve(100e6, 500e6);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxMint = syncManager.maxMint(vault, USER);

        assertEq(maxMint, 0, "maxMint should return 0 when reserve is exceeded");
    }
}

/// @title SyncManagerMaxDepositMintConsistencyTest
/// @notice Tests mathematical consistency between maxDeposit, maxMint, and conversion functions
contract SyncManagerMaxDepositMintConsistencyTest is SyncManagerBaseTest {
    function testMaxDepositMintConsistency() public {
        _setupVaultDetails(6, 18);

        D18 poolPerShare = d18(4, 1);
        D18 poolPerAsset = d18(2, 1);
        _setupPrices(poolPerShare, poolPerAsset);

        _setupMaxReserve(1000e6, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
        uint256 maxMint = syncManager.maxMint(vault, USER);

        uint256 expectedShares = syncManager.convertToShares(vault, maxDeposit);
        assertEq(maxMint, expectedShares, "maxMint should equal convertToShares(maxDeposit)");

        // Verify inverse
        uint256 assetsForMaxMint = syncManager.convertToAssets(vault, maxMint);
        assertApproxEqAbs(assetsForMaxMint, maxDeposit, 1, "Inverse conversion should match");
    }

    function testMaxDepositMintWithVariousPriceRatios() public {
        _setupVaultDetails(18, 18);
        _setupMaxReserve(type(uint128).max, 0);
        _setupLinkedVault(true);
        _setupTransferRestriction(true);

        D18[4] memory poolPerShareValues = [d18(1, 1), d18(2, 1), d18(1, 2), d18(15, 10)];
        D18[4] memory poolPerAssetValues = [d18(1, 1), d18(1, 2), d18(3, 1), d18(2, 1)];

        for (uint256 i = 0; i < 4; i++) {
            _setupPrices(poolPerShareValues[i], poolPerAssetValues[i]);

            uint256 maxDeposit = syncManager.maxDeposit(vault, USER);
            uint256 maxMint = syncManager.maxMint(vault, USER);

            uint256 expectedShares = syncManager.convertToShares(vault, maxDeposit);
            assertEq(maxMint, expectedShares, string(abi.encodePacked("Consistency failed for ratio ", vm.toString(i))));

            assertTrue(maxDeposit > 0, "maxDeposit should be positive");
            assertTrue(maxMint > 0, "maxMint should be positive");
        }
    }
}
