// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {RequestCallbackMessageLib} from "../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";

contract AssetShareConversionTest is CentrifugeIntegrationTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;
    using RequestCallbackMessageLib for *;

    PoolId POOL_A;
    ShareClassId SC_1;

    function setUp() public override {
        super.setUp();
        // address(this) is FM — all hub calls work without a prank
        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, address(this), USD_ID);
    }

    function _newErc20(string memory name, string memory symbol, uint8 shareDecimals) internal returns (ERC20) {
        ERC20 asset = new ERC20(shareDecimals);
        asset.file("name", name);
        asset.file("symbol", symbol);
        return asset;
    }

    /// Sets up an async vault for the given asset, returns the assetId and vault.
    function _deployVault(ERC20 asset) internal returns (AssetId assetId, AsyncVault vault) {
        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);
        hub.addShareClass(POOL_A, "TestShare", "TST", bytes32(bytes8(POOL_A.raw())));

        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(fullRestrictionsHook))), address(this)
        );

        // Initial share price on spoke
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerShare(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));

        // Register asset (same-chain short-circuit: also registers on hub via hubHandler)
        assetId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));

        // Initial asset price on spoke
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, assetId, d18(1, 1), uint64(block.timestamp));

        // Set request managers (hub-side: batchRequestManager, spoke-side: asyncRequestManager)
        hub.setRequestManager{value: 0}(
            POOL_A,
            LOCAL_CENTRIFUGE_ID,
            batchRequestManager,
            bytes32(bytes20(address(asyncRequestManager))),
            address(this)
        );

        // Allow asyncRequestManager to call balance sheet operations for this pool
        hub.updateBalanceSheetManager{value: 0}(
            POOL_A, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(asyncRequestManager))), true, address(this)
        );

        // Deploy and link vault (same-chain short-circuit: goes directly to vaultRegistry)
        hub.updateVault{value: 0}(
            POOL_A,
            SC_1,
            assetId,
            bytes32(bytes20(address(asyncVaultFactory))),
            VaultUpdateKind.DeployAndLink,
            0,
            address(this)
        );

        vault = AsyncVault(IShareToken(spoke.shareToken(POOL_A, SC_1)).vault(address(asset)));
    }

    /// Simulates the hub sending back deposit fulfillment messages to the spoke.
    /// Prices are hardcoded to 1:1 (matching MockCentrifugeChain.isFulfilledDepositRequest behaviour).
    function _fulfillDeposit(AssetId assetId, address investor, uint128 assetAmount, uint128 shareAmount) internal {
        vm.prank(address(messageProcessor));
        spoke.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.ApprovedDeposits({assetAmount: assetAmount, pricePoolPerAsset: d18(1, 1).raw()})
                .serialize()
        );

        vm.prank(address(messageProcessor));
        spoke.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.IssuedShares({shareAmount: shareAmount, pricePoolPerShare: d18(1, 1).raw()})
                .serialize()
        );

        vm.prank(address(messageProcessor));
        spoke.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.FulfilledDepositRequest({
                    investor: investor.toBytes32(),
                    fulfilledAssetAmount: assetAmount,
                    fulfilledShareAmount: shareAmount,
                    cancelledAssetAmount: 0
                }).serialize()
        );
    }

    /// forge-config: default.isolate = true
    function testAssetShareConversion() public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6; // like USDC, share token always has 18 decimals (pool currency)

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (AssetId assetId, AsyncVault vault) = _deployVault(asset);
        IShareToken shareToken = IShareToken(vault.share());

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);

        // Updating with same values confirms reads are correct (no-op)
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerShare(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, assetId, d18(1, 1), uint64(block.timestamp));

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1e6);

        // Invest
        uint256 investmentAmount = 100000000; // 100 * 10**6
        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(address(this).toBytes32(), type(uint64).max)
                .serialize(),
            0,
            address(this)
        );
        asset.approve(address(vault), investmentAmount);
        asset.mint(address(this), investmentAmount);
        vault.requestDeposit(investmentAmount, address(this), address(this));

        assertEq(asset.balanceOf(address(balanceSheet.escrow(POOL_A))), investmentAmount);

        // Trigger fulfilled deposit at price 1:1 (100 assets → 100 shares at 18 decimals)
        uint128 shares = 100000000000000000000; // 100 * 10**18
        _fulfillDeposit(assetId, address(this), uint128(investmentAmount), shares);

        vault.mint(shares, address(this));

        // Confirm price still 1:1 after claim
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerShare(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));

        // Assert share/asset conversion (shares have 12 more decimals than assets)
        assertEq(shareToken.totalSupply(), 100000000000000000000);
        assertEq(vault.totalAssets(), 100000000);
        assertEq(vault.convertToShares(100000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e6);

        // Price update to 1.2
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerShare(POOL_A, SC_1, D18.wrap(1200000000000000000), uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000);
        assertEq(vault.convertToShares(120000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e6);

        // Asset price halved: 1 pool unit = 2 asset units, so 1 share = 1.2 pool = 2.4 assets
        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, assetId, D18.wrap(0.5e18), uint64(block.timestamp));

        assertEq(vault.totalAssets(), 240000000);
        assertEq(vault.convertToShares(240000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(240000000000000000000)), 240000000000000000000);
        assertEq(vault.pricePerShare(), 2.4e6);
    }

    /// forge-config: default.isolate = true
    function testPriceWorksAfterRemovingVault() public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6;

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (AssetId assetId, AsyncVault vault) = _deployVault(asset);

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);

        vm.prank(address(messageProcessor));
        spoke.updatePricePoolPerShare(POOL_A, SC_1, D18.wrap(1.2e18), uint64(block.timestamp));

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);

        // Unlink vault — price reads should still work since they go through the share class
        vm.prank(address(messageProcessor));
        vaultRegistry.unlinkVault(POOL_A, SC_1, assetId, vault);

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);
    }
}
