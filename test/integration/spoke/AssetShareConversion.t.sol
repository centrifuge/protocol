// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultUpdateKind, ManagerKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {RequestCallbackMessageLib} from "../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

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

    /// Sets up an async vault for the given asset in the given pool, returns the assetId and vault.
    /// Sets the module-level `SC_1` for the deployed share class so `_fulfill*` helpers can key off it.
    function _deployVault(PoolId poolId, ERC20 asset) internal returns (AssetId assetId, AsyncVault vault) {
        SC_1 = shareClassManager.previewNextShareClassId(poolId);
        hub.addShareClass(poolId, "TestShare", "TST", bytes32(bytes8(poolId.raw())));

        hub.notifyPool{value: 0}(poolId, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(
            poolId, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(shareTokenRegistrar))), "", 0, address(this)
        );

        // Token deploys hookless (v3.1+); set the restriction hook via the registrar's Envoy path
        hub.managerCall{value: 0}(
            poolId,
            LOCAL_CENTRIFUGE_ID,
            address(shareTokenRegistrar).toBytes32(),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), SC_1, address(fullRestrictionsHook)),
            0,
            0,
            address(this)
        );

        // Initial share price on spoke
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerShare(poolId, SC_1, d18(1, 1), uint64(block.timestamp));

        // Register asset (same-chain short-circuit: also registers on hub via hubHandler)
        assetId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));

        // Initial asset price on spoke
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerAsset(poolId, SC_1, assetId, d18(1, 1), uint64(block.timestamp));

        // Set request managers (hub-side: batchRequestManager, spoke-side: asyncRequestManager)
        hub.setRequestManager{value: 0}(
            poolId,
            LOCAL_CENTRIFUGE_ID,
            batchRequestManager,
            bytes32(bytes20(address(asyncRequestManager))),
            address(this)
        );

        // Allow asyncRequestManager to call balance sheet operations for this pool
        hub.updateManager{value: 0}(
            poolId,
            LOCAL_CENTRIFUGE_ID,
            ManagerKind.Spoke,
            bytes32(bytes20(address(asyncRequestManager))),
            true,
            address(this)
        );

        // Deploy and link vault (same-chain short-circuit: goes directly to vaultRegistry)
        vm.recordLogs();
        hub.updateVault{value: 0}(
            poolId,
            SC_1,
            assetId,
            bytes32(bytes20(address(asyncVaultFactory))),
            VaultUpdateKind.DeployAndLink,
            bytes(""),
            0,
            address(this)
        );

        vault = AsyncVault(_deployedVaultFromLogs());

        hub.managerCall{value: 0}(
            poolId,
            LOCAL_CENTRIFUGE_ID,
            address(shareTokenRegistrar).toBytes32(),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetVault), SC_1, assetId.raw(), address(vault)),
            0,
            0,
            address(this)
        );
    }

    /// Simulates the hub sending back deposit fulfillment messages to the spoke.
    /// Prices are hardcoded to 1:1 (matching MockCentrifugeChain.isFulfilledDepositRequest behaviour).
    function _fulfillDeposit(AssetId assetId, address investor, uint128 assetAmount, uint128 shareAmount) internal {
        vm.prank(address(messageProcessor));
        spokeHandler.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.ApprovedDeposits({assetAmount: assetAmount, pricePoolPerAsset: d18(1, 1).raw()})
                .serialize()
        );

        vm.prank(address(messageProcessor));
        spokeHandler.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.IssuedShares({shareAmount: shareAmount, pricePoolPerShare: d18(1, 1).raw()})
                .serialize()
        );

        vm.prank(address(messageProcessor));
        spokeHandler.requestCallback(
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
        (AssetId assetId, AsyncVault vault) = _deployVault(POOL_A, asset);
        IShareToken shareToken = IShareToken(vault.share());

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);

        // Updating with same values confirms reads are correct (no-op)
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerShare(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerAsset(POOL_A, SC_1, assetId, d18(1, 1), uint64(block.timestamp));

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

        assertEq(asset.balanceOf(address(spoke.escrow(POOL_A))), investmentAmount);

        // Trigger fulfilled deposit at price 1:1 (100 assets → 100 shares at 18 decimals)
        uint128 shares = 100000000000000000000; // 100 * 10**18
        _fulfillDeposit(assetId, address(this), uint128(investmentAmount), shares);

        vault.mint(shares, address(this));

        // Confirm price still 1:1 after claim
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerShare(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));

        // Assert share/asset conversion (shares have 12 more decimals than assets)
        assertEq(shareToken.totalSupply(), 100000000000000000000);
        assertEq(vault.totalAssets(), 100000000);
        assertEq(vault.convertToShares(100000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(100000000000000000000)), 100000000000000000000);
        assertEq(vault.pricePerShare(), 1e6);

        // Price update to 1.2
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerShare(POOL_A, SC_1, D18.wrap(1200000000000000000), uint64(block.timestamp));

        assertEq(vault.totalAssets(), 120000000);
        assertEq(vault.convertToShares(120000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(120000000000000000000)), 120000000000000000000);
        assertEq(vault.pricePerShare(), 1.2e6);

        // Asset price halved: 1 pool unit = 2 asset units, so 1 share = 1.2 pool = 2.4 assets
        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerAsset(POOL_A, SC_1, assetId, D18.wrap(0.5e18), uint64(block.timestamp));

        assertEq(vault.totalAssets(), 240000000);
        assertEq(vault.convertToShares(240000000), 100000000000000000000);
        assertEq(vault.convertToAssets(vault.convertToShares(240000000000000000000)), 240000000000000000000);
        assertEq(vault.pricePerShare(), 2.4e6);
    }

    /// Simulates the hub sending back redeem fulfillment messages to the spoke at price 1:1.
    function _fulfillRedeem(AssetId assetId, address investor, uint128 assetAmount, uint128 shareAmount) internal {
        vm.prank(address(messageProcessor));
        spokeHandler.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.RevokedShares({
                    assetAmount: assetAmount, shareAmount: shareAmount, pricePoolPerShare: d18(1, 1).raw()
                }).serialize()
        );

        vm.prank(address(messageProcessor));
        spokeHandler.requestCallback(
            POOL_A,
            SC_1,
            assetId,
            RequestCallbackMessageLib.FulfilledRedeemRequest({
                    investor: investor.toBytes32(),
                    fulfilledAssetAmount: assetAmount,
                    fulfilledShareAmount: shareAmount,
                    cancelledShareAmount: 0
                }).serialize()
        );
    }

    function _addMember(address investor) internal {
        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(investor.toBytes32(), type(uint64).max).serialize(),
            0,
            address(this)
        );
    }

    /// 0-decimal asset into an 18-decimal pool (coarse asset, fine shares): full async deposit + redeem cycle.
    /// forge-config: default.isolate = true
    function testZeroDecimalAssetFullCycle() public {
        ERC20 asset = _newErc20("ZeroDec", "ZD", 0);
        (AssetId assetId, AsyncVault vault) = _deployVault(POOL_A, asset);
        IShareToken shareToken = IShareToken(vault.share());

        // 1 whole (0-dec) asset per 1.0 share at price 1:1.
        assertEq(vault.pricePerShare(), 1, "pricePerShare = convertToAssets(1e18 shares) = 1 whole asset unit");

        _addMember(address(this));

        // Deposit 100 whole units of the 0-decimal asset.
        uint128 assets = 100;
        asset.mint(address(this), assets);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, address(this), address(this));
        assertEq(asset.balanceOf(address(spoke.escrow(POOL_A))), assets, "assets escrowed");

        // Fulfilled 1:1 -> 100.0 shares (18 decimals).
        uint128 shares = 100e18;
        _fulfillDeposit(assetId, address(this), assets, shares);
        vault.mint(shares, address(this));

        assertEq(shareToken.totalSupply(), shares);
        assertEq(vault.totalAssets(), assets);
        assertEq(vault.convertToShares(assets), shares);
        assertEq(vault.convertToAssets(shares), assets);

        assertEq(vault.convertToAssets(5e17), 0, "half a fine share rounds to 0 coarse units");

        vault.requestRedeem(shares, address(this), address(this));
        _fulfillRedeem(assetId, address(this), assets, shares);

        vault.withdraw(vault.maxWithdraw(address(this)), address(this), address(this));

        assertEq(asset.balanceOf(address(this)), assets, "investor recovered all assets");
        assertEq(shareToken.totalSupply(), 0, "all shares burned");
        assertEq(asset.balanceOf(address(spoke.escrow(POOL_A))), 0, "escrow fully drained");
    }

    /// Dust: a fine-share redemption whose asset payout rounds to 0 must not revert or lock the position.
    /// forge-config: default.isolate = true
    function testZeroDecimalAssetDustPayout() public {
        ERC20 asset = _newErc20("ZeroDec", "ZD", 0);
        (AssetId assetId, AsyncVault vault) = _deployVault(POOL_A, asset);
        IShareToken shareToken = IShareToken(vault.share());

        _addMember(address(this));

        uint128 assets = 100;
        asset.mint(address(this), assets);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, address(this), address(this));
        uint128 shares = 100e18;
        _fulfillDeposit(assetId, address(this), assets, shares);
        vault.mint(shares, address(this));

        uint256 escrowBefore = asset.balanceOf(address(spoke.escrow(POOL_A)));

        // Redeem half a fine share: the hub fulfills 0 whole asset units for it (dust rounds down).
        uint128 dustShares = 5e17;
        vault.requestRedeem(dustShares, address(this), address(this));

        // Fulfilling a 0-asset redemption must not revert.
        _fulfillRedeem(assetId, address(this), 0, dustShares);

        // The dust shares are burned (the documented rounding loss); nothing is claimable and no assets move.
        assertEq(vault.maxWithdraw(address(this)), 0, "dust redemption yields 0 claimable assets");
        assertEq(shareToken.totalSupply(), shares - dustShares, "dust shares burned on revoke");
        assertEq(asset.balanceOf(address(this)), 0, "no assets paid for dust");
        assertEq(asset.balanceOf(address(spoke.escrow(POOL_A))), escrowBefore, "escrowed assets untouched by dust");
    }

    /// Dust via partial claim: a nonzero redeem is fulfilled, then a PARTIAL claim whose asset payout rounds
    /// down to 0 must not revert, must pay 0 assets, and must decay maxWithdraw/maxRedeem by the round-up asset
    /// cost. The claimant loses exactly one asset unit (the documented rounding remainder, left in escrow).
    /// forge-config: default.isolate = true
    function testZeroDecimalAssetPartialDustClaim() public {
        ERC20 asset = _newErc20("ZeroDec", "ZD", 0);
        (AssetId assetId, AsyncVault vault) = _deployVault(POOL_A, asset);

        _addMember(address(this));

        uint128 assets = 100;
        asset.mint(address(this), assets);
        asset.approve(address(vault), assets);
        vault.requestDeposit(assets, address(this), address(this));
        uint128 shares = 100e18;
        _fulfillDeposit(assetId, address(this), assets, shares);
        vault.mint(shares, address(this));

        // Fulfill the full redeem with a nonzero total (100 whole asset units for 100.0 shares, 1:1).
        vault.requestRedeem(shares, address(this), address(this));
        _fulfillRedeem(assetId, address(this), assets, shares);

        // maxWithdraw is asset-denominated (source of truth); maxRedeem is derived from it at redeemPrice 1:1.
        assertEq(vault.maxWithdraw(address(this)), assets, "claimable assets before dust");
        assertEq(vault.maxRedeem(address(this)), shares, "claimable shares before dust");

        // Claim by redeeming half a fine share: worth < 1 whole asset unit, so the payout rounds down to 0.
        uint128 dustShares = 5e17;
        uint256 paid = vault.redeem(dustShares, address(this), address(this));

        // No revert; 0 assets paid; maxWithdraw decays by exactly the round-up cost of 1 asset unit; maxRedeem
        // recomputes from the decayed maxWithdraw (so it drops by a full 1e18 shares, not just dustShares).
        assertEq(paid, 0, "dust claim pays 0 assets");
        assertEq(asset.balanceOf(address(this)), 0, "no assets received for dust claim");
        assertEq(vault.maxWithdraw(address(this)), assets - 1, "maxWithdraw decays by one asset unit");
        assertEq(vault.maxRedeem(address(this)), 99e18, "maxRedeem recomputes from decayed maxWithdraw at 1:1");

        vault.withdraw(vault.maxWithdraw(address(this)), address(this), address(this));
        assertEq(asset.balanceOf(address(this)), assets - 1, "investor recovers all but the 1-unit dust remainder");
        assertEq(asset.balanceOf(address(spoke.escrow(POOL_A))), 1, "1-unit rounding remainder left in escrow");
    }

    /// 18-decimal asset into a pool denominated in a 0-decimal currency: the spoke must accept a 0-decimal
    /// share class, and `pricePerShare` must use `10 ** 0 = 1` (convertToAssets(1)).
    /// forge-config: default.isolate = true
    function testZeroDecimalCurrencyPool() public {
        // Register a 0-decimal asset to serve as the pool currency (same-chain: also registered on the hub).
        ERC20 currency = _newErc20("ZeroCurrency", "ZC", 0);
        AssetId currencyId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(currency), 0, address(this));

        // Create a pool denominated in the 0-decimal currency.
        PoolId poolB = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 2);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(poolB, address(this), currencyId);
        assertEq(hubRegistry.decimals(poolB), 0, "pool currency is 0-decimal");

        // Deploy an 18-decimal investment asset vault into the 0-decimal-currency pool.
        ERC20 asset = _newErc20("Asset", "A", 18);
        (, AsyncVault vault) = _deployVault(poolB, asset);

        // notifyShareClass carried decimals(poolB) = 0, so the spoke deployed a 0-decimal share token.
        IShareToken shareToken = IShareToken(vault.share());
        assertEq(shareToken.decimals(), 0, "share token inherits 0-decimal pool currency");

        assertEq(vault.convertToAssets(1), 1e18, "one 0-dec share converts to 1e18 asset units");
        assertEq(vault.pricePerShare(), 1e18, "pricePerShare uses 10**0 = 1 share unit");
    }

    /// forge-config: default.isolate = true
    function testPriceWorksAfterRemovingVault() public {
        uint8 INVESTMENT_CURRENCY_DECIMALS = 6;

        ERC20 asset = _newErc20("Asset", "A", INVESTMENT_CURRENCY_DECIMALS);
        (AssetId assetId, AsyncVault vault) = _deployVault(POOL_A, asset);

        assertEq(vault.priceLastUpdated(), block.timestamp);
        assertEq(vault.pricePerShare(), 1e6);

        vm.prank(address(messageProcessor));
        spokeHandler.updatePricePoolPerShare(POOL_A, SC_1, D18.wrap(1.2e18), uint64(block.timestamp));

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);

        // Unlink vault — price reads should still work since they go through the share class
        hub.updateVault{value: 0}(
            POOL_A, SC_1, assetId, bytes32(bytes20(address(vault))), VaultUpdateKind.Unlink, bytes(""), 0, address(this)
        );

        assertEq(vault.priceLastUpdated(), uint64(block.timestamp));
        assertEq(vault.pricePerShare(), 1.2e6);
    }
}
