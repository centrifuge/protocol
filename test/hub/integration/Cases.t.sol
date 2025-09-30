// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./BaseTest.sol";

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {RequestCallbackMessageLib} from "../../../src/common/libraries/RequestCallbackMessageLib.sol";

import {IHubRequestManager} from "../../../src/hub/interfaces/IHubRequestManager.sol";

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
        hub.notifyPool{value: GAS}(poolId, CHAIN_CV, REFUND);
        hub.notifyShareClass{value: GAS}(poolId, scId, CHAIN_CV, SC_HOOK, REFUND);
        hub.setRequestManager{
            value: GAS
        }(poolId, CHAIN_CV, IHubRequestManager(hubRequestManager), ASYNC_REQUEST_MANAGER.toBytes32(), REFUND);
        hub.updateBalanceSheetManager{value: GAS}(CHAIN_CV, poolId, ASYNC_REQUEST_MANAGER.toBytes32(), true, REFUND);
        hub.updateBalanceSheetManager{value: GAS}(CHAIN_CV, poolId, SYNC_REQUEST_MANAGER.toBytes32(), true, REFUND);

        hub.createAccount(poolId, ASSET_USDC_ACCOUNT, true);
        hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        hub.createAccount(poolId, LOSS_ACCOUNT, false);
        hub.createAccount(poolId, GAIN_ACCOUNT, false);
        hub.createAccount(poolId, ASSET_EUR_STABLE_ACCOUNT, true);
        if (withInitialization) {
            valuation.setPrice(poolId, scId, USDC_C2, d18(1, 1));
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
        hub.updateVault{value: GAS}(poolId, scId, USDC_C2, bytes32("factory"), VaultUpdateKind.DeployAndLink, 0, REFUND);

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

        valuation.setPrice(poolId, scId, USDC_C2, d18(11, 10));
        hub.updateHoldingValue(poolId, scId, USDC_C2);

        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 440 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 40 * poolDecimals);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        valuation.setPrice(poolId, scId, USDC_C2, d18(8, 10));
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

        valuation.setPrice(poolId, scId, EUR_STABLE_C2, poolPerEurPrice);

        vm.startPrank(FM);
        hub.updateSharePrice(poolId, scId, sharePrice);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, EUR_STABLE_C2, REFUND);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, USDC_C2, REFUND);
        hub.notifySharePrice{value: GAS}(poolId, scId, CHAIN_CV, REFUND);

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
