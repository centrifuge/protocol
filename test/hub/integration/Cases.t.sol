// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./BaseTest.sol";

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {RequestCallbackMessageLib} from "../../../src/common/libraries/RequestCallbackMessageLib.sol";

contract TestCases is BaseTest {
    using MathLib for *;
    using MessageLib for *;
    using RequestCallbackMessageLib for *;
    using PricingLib for *;
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testPoolCreation(bool withInitialization) public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, 6);
        cv.registerAsset(EUR_STABLE_C2, 12);

        poolId = hubRegistry.poolId(CHAIN_CP, 1);
        vm.prank(ADMIN);
        guardian.createPool(poolId, FM, USD_ID);

        scId = shareClassManager.previewNextShareClassId(poolId);

        vm.startPrank(FM);
        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);
        hub.notifyPool{value: GAS}(poolId, CHAIN_CV);
        hub.notifyShareClass{value: GAS}(poolId, scId, CHAIN_CV, SC_HOOK);
        hub.setRequestManager{value: GAS}(poolId, scId, USDC_C2, ASYNC_REQUEST_MANAGER.toBytes32());
        hub.updateBalanceSheetManager{value: GAS}(CHAIN_CV, poolId, ASYNC_REQUEST_MANAGER.toBytes32(), true);
        hub.updateBalanceSheetManager{value: GAS}(CHAIN_CV, poolId, SYNC_REQUEST_MANAGER.toBytes32(), true);

        hub.createAccount(poolId, ASSET_USDC_ACCOUNT, true);
        hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        hub.createAccount(poolId, LOSS_ACCOUNT, false);
        hub.createAccount(poolId, GAIN_ACCOUNT, false);
        hub.createAccount(poolId, ASSET_EUR_STABLE_ACCOUNT, true);
        if (withInitialization) {
            valuation.setPrice(USDC_C2, hubRegistry.currency(poolId), d18(1, 1));
            hub.initializeHolding(
                poolId, scId, USDC_C2, valuation, ASSET_USDC_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
            );
            hub.initializeHolding(
                poolId,
                scId,
                EUR_STABLE_C2,
                valuation,
                ASSET_EUR_STABLE_ACCOUNT,
                EQUITY_ACCOUNT,
                GAIN_ACCOUNT,
                LOSS_ACCOUNT
            );
        }
        hub.updateVault{value: GAS}(poolId, scId, USDC_C2, bytes32("factory"), VaultUpdateKind.DeployAndLink, 0);

        MessageLib.NotifyPool memory m0 = MessageLib.deserializeNotifyPool(cv.popMessage());
        assertEq(m0.poolId, poolId.raw());

        MessageLib.NotifyShareClass memory m1 = MessageLib.deserializeNotifyShareClass(cv.popMessage());
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.name, SC_NAME);
        assertEq(m1.symbol, SC_SYMBOL.toBytes32());
        assertEq(m1.decimals, 18);
        assertEq(m1.salt, SC_SALT);
        assertEq(m1.hook, SC_HOOK);

        MessageLib.SetRequestManager memory m2 = MessageLib.deserializeSetRequestManager(cv.popMessage());
        assertEq(m2.poolId, poolId.raw());
        assertEq(m2.scId, scId.raw());
        assertEq(m2.assetId, USDC_C2.raw());
        assertEq(m2.manager, ASYNC_REQUEST_MANAGER.toBytes32());

        MessageLib.UpdateBalanceSheetManager memory m3 =
            MessageLib.deserializeUpdateBalanceSheetManager(cv.popMessage());
        assertEq(m3.poolId, poolId.raw());
        assertEq(m3.who, ASYNC_REQUEST_MANAGER.toBytes32());
        assertEq(m3.canManage, true);

        MessageLib.UpdateBalanceSheetManager memory m4 =
            MessageLib.deserializeUpdateBalanceSheetManager(cv.popMessage());
        assertEq(m4.poolId, poolId.raw());
        assertEq(m4.who, SYNC_REQUEST_MANAGER.toBytes32());
        assertEq(m4.canManage, true);

        MessageLib.UpdateVault memory m5 = MessageLib.deserializeUpdateVault(cv.popMessage());
        assertEq(m5.poolId, poolId.raw());
        assertEq(m5.scId, scId.raw());
        assertEq(m5.assetId, USDC_C2.raw());
        assertEq(m5.vaultOrFactory, bytes32("factory"));
        assertEq(m5.kind, uint8(VaultUpdateKind.DeployAndLink));
    }

    /// forge-config: default.isolate = true
    function testDeposit() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testPoolCreation(true);

        cv.requestDeposit(poolId, scId, USDC_C2, INVESTOR, INVESTOR_AMOUNT);

        vm.startPrank(FM);
        hub.approveDeposits{value: GAS}(
            poolId, scId, USDC_C2, shareClassManager.nowDepositEpoch(scId, USDC_C2), APPROVED_INVESTOR_AMOUNT
        );
        hub.issueShares{value: GAS}(
            poolId, scId, USDC_C2, shareClassManager.nowIssueEpoch(scId, USDC_C2), NAV_PER_SHARE, SHARE_HOOK_GAS
        );

        // Queue cancellation request which is fulfilled when claiming
        cv.cancelDepositRequest(poolId, scId, USDC_C2, INVESTOR);

        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.notifyDeposit{value: GAS}(
            poolId, scId, USDC_C2, INVESTOR, shareClassManager.maxDepositClaims(scId, INVESTOR, USDC_C2)
        );

        MessageLib.RequestCallback memory m0 = MessageLib.deserializeRequestCallback(cv.popMessage());
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.assetId, USDC_C2.raw());

        RequestCallbackMessageLib.ApprovedDeposits memory cb0 =
            RequestCallbackMessageLib.deserializeApprovedDeposits(m0.payload);
        assertEq(cb0.assetAmount, APPROVED_INVESTOR_AMOUNT);

        MessageLib.RequestCallback memory m1 = MessageLib.deserializeRequestCallback(cv.popMessage());
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.assetId, USDC_C2.raw());

        RequestCallbackMessageLib.IssuedShares memory cb1 =
            RequestCallbackMessageLib.deserializeIssuedShares(m1.payload);
        assertEq(cb1.pricePoolPerShare, NAV_PER_SHARE.raw());

        MessageLib.RequestCallback memory m2 = MessageLib.deserializeRequestCallback(cv.popMessage());
        assertEq(m2.poolId, poolId.raw());
        assertEq(m2.scId, scId.raw());
        assertEq(m2.assetId, USDC_C2.raw());

        RequestCallbackMessageLib.FulfilledDepositRequest memory cb2 =
            RequestCallbackMessageLib.deserializeFulfilledDepositRequest(m2.payload);
        assertEq(cb2.investor, INVESTOR);
        assertEq(cb2.fulfilledAssetAmount, APPROVED_INVESTOR_AMOUNT);
        assertEq(
            cb2.fulfilledShareAmount,
            PricingLib.convertWithPrice(
                APPROVED_INVESTOR_AMOUNT,
                hubRegistry.decimals(USDC_C2),
                hubRegistry.decimals(poolId),
                NAV_PER_SHARE.reciprocal()
            )
        );
        assertEq(cb2.cancelledAssetAmount, INVESTOR_AMOUNT - APPROVED_INVESTOR_AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testRedeem() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testDeposit();

        cv.requestRedeem(poolId, scId, USDC_C2, INVESTOR, SHARE_AMOUNT);

        uint128 revokedAssetAmount = PricingLib.convertWithPrice(
            APPROVED_SHARE_AMOUNT, hubRegistry.decimals(poolId), hubRegistry.decimals(USDC_C2), NAV_PER_SHARE
        );

        vm.startPrank(FM);
        hub.approveRedeems(
            poolId, scId, USDC_C2, shareClassManager.nowRedeemEpoch(scId, USDC_C2), APPROVED_SHARE_AMOUNT
        );
        hub.revokeShares{value: GAS}(
            poolId, scId, USDC_C2, shareClassManager.nowRevokeEpoch(scId, USDC_C2), NAV_PER_SHARE, SHARE_HOOK_GAS
        );

        // Queue cancellation request which is fulfilled when claiming
        cv.cancelRedeemRequest(poolId, scId, USDC_C2, INVESTOR);

        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.notifyRedeem{value: GAS}(
            poolId, scId, USDC_C2, INVESTOR, shareClassManager.maxRedeemClaims(scId, INVESTOR, USDC_C2)
        );

        MessageLib.RequestCallback memory m0 = MessageLib.deserializeRequestCallback(cv.popMessage());
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.assetId, USDC_C2.raw());

        RequestCallbackMessageLib.RevokedShares memory cb0 =
            RequestCallbackMessageLib.deserializeRevokedShares(m0.payload);
        assertEq(cb0.assetAmount, revokedAssetAmount);
        assertEq(cb0.shareAmount, APPROVED_SHARE_AMOUNT);
        assertEq(cb0.pricePoolPerShare, NAV_PER_SHARE.raw());

        MessageLib.RequestCallback memory m1 = MessageLib.deserializeRequestCallback(cv.popMessage());
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.assetId, USDC_C2.raw());

        RequestCallbackMessageLib.FulfilledRedeemRequest memory cb1 =
            RequestCallbackMessageLib.deserializeFulfilledRedeemRequest(m1.payload);
        assertEq(cb1.investor, INVESTOR);
        assertEq(cb1.fulfilledAssetAmount, revokedAssetAmount);
        assertEq(cb1.fulfilledShareAmount, APPROVED_SHARE_AMOUNT);
        assertEq(cb1.cancelledShareAmount, SHARE_AMOUNT - APPROVED_SHARE_AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testUpdateHolding() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(false);
        uint128 poolDecimals = (10 ** hubRegistry.decimals(USD_ID.raw())).toUint128();
        uint128 assetDecimals = (10 ** hubRegistry.decimals(USDC_C2.raw())).toUint128();

        cv.updateHoldingAmount(poolId, scId, USDC_C2, 1000 * assetDecimals, D18.wrap(1e18), true, IS_SNAPSHOT, 0);

        assertEq(holdings.amount(poolId, scId, USDC_C2), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 1000 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        hub.initializeHolding(
            poolId, scId, USDC_C2, valuation, ASSET_USDC_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );

        assertEq(holdings.amount(poolId, scId, USDC_C2), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 1000 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 1000 * poolDecimals);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 1000 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        cv.updateHoldingAmount(poolId, scId, USDC_C2, 600 * assetDecimals, D18.wrap(1e18), false, IS_SNAPSHOT, 1);

        assertEq(holdings.amount(poolId, scId, USDC_C2), 400 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 400 * poolDecimals);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        valuation.setPrice(USDC_C2, hubRegistry.currency(poolId), d18(11, 10));
        hub.updateHoldingValue(poolId, scId, USDC_C2);

        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 440 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 40 * poolDecimals);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        valuation.setPrice(USDC_C2, hubRegistry.currency(poolId), d18(8, 10));
        hub.updateHoldingValue(poolId, scId, USDC_C2);

        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 320 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 40 * poolDecimals);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, false, 120 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testUpdateShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(true);

        cv.updateShares(poolId, scId, 100, true, IS_SNAPSHOT, 0);

        (uint128 totalIssuance,) = shareClassManager.metrics(scId);
        assertEq(totalIssuance, 100);

        cv.updateShares(poolId, scId, 45, false, IS_SNAPSHOT, 1);

        (uint128 totalIssuance2,) = shareClassManager.metrics(scId);
        assertEq(totalIssuance2, 55);
    }

    /// forge-config: default.isolate = true
    function testNotifyPricePoolPerShare() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(true);
        D18 sharePrice = d18(100, 1);
        D18 identityPrice = d18(1, 1);
        D18 poolPerEurPrice = d18(4, 1);
        AssetId poolCurrency = hubRegistry.currency(poolId);

        valuation.setPrice(EUR_STABLE_C2, poolCurrency, poolPerEurPrice);

        vm.startPrank(FM);
        hub.updateSharePrice(poolId, scId, sharePrice);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, EUR_STABLE_C2);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, USDC_C2);
        hub.notifySharePrice{value: GAS}(poolId, scId, CHAIN_CV);

        MessageLib.NotifyPricePoolPerAsset memory m0 = MessageLib.deserializeNotifyPricePoolPerAsset(cv.popMessage());
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.assetId, EUR_STABLE_C2.raw());
        assertEq(m0.price, poolPerEurPrice.raw(), "EUR price mismatch");
        assertEq(m0.timestamp, block.timestamp.toUint64());

        MessageLib.NotifyPricePoolPerAsset memory m1 = MessageLib.deserializeNotifyPricePoolPerAsset(cv.popMessage());
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.assetId, USDC_C2.raw());
        assertEq(m1.price, identityPrice.raw(), "USDC price mismatch");
        assertEq(m1.timestamp, block.timestamp.toUint64());

        MessageLib.NotifyPricePoolPerShare memory m2 = MessageLib.deserializeNotifyPricePoolPerShare(cv.popMessage());
        assertEq(m2.poolId, poolId.raw());
        assertEq(m2.scId, scId.raw());
        assertEq(m2.price, sharePrice.raw(), "Share price mismatch");
        assertEq(m2.timestamp, block.timestamp.toUint64());
    }
}
