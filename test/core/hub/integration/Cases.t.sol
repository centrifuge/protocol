// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./BaseTest.sol";

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {PricingLib} from "../../../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {MessageLib} from "../../../../src/core/messaging/libraries/MessageLib.sol";
import {VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";
import {IHubRequestManager} from "../../../../src/core/hub/interfaces/IHubRequestManager.sol";

import {RequestCallbackMessageLib} from "../../../../src/vaults/libraries/RequestCallbackMessageLib.sol";

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
        opsGuardian.createPool(poolId, FM, USD_ID);

        scId = shareClassManager.previewNextShareClassId(poolId);

        vm.startPrank(FM);
        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);
        hub.notifyPool{value: GAS}(poolId, CHAIN_CV, REFUND);
        hub.notifyShareClass{value: GAS}(poolId, scId, CHAIN_CV, SC_HOOK, REFUND);
        hub.setRequestManager{
            value: GAS
        }(poolId, CHAIN_CV, IHubRequestManager(hubRequestManager), ASYNC_REQUEST_MANAGER.toBytes32(), REFUND);
        hub.updateBalanceSheetManager{value: GAS}(poolId, CHAIN_CV, ASYNC_REQUEST_MANAGER.toBytes32(), true, REFUND);
        hub.updateBalanceSheetManager{value: GAS}(poolId, CHAIN_CV, SYNC_REQUEST_MANAGER.toBytes32(), true, REFUND);

        hub.createAccount(poolId, ASSET_USDC_ACCOUNT, true);
        hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        hub.createAccount(poolId, GAIN_ACCOUNT, false);
        hub.createAccount(poolId, LOSS_ACCOUNT, true);
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
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 120 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testUpdateLiability() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(false);
        cv.registerAsset(FEE_C2, 18);

        hub.createAccount(poolId, FEE_ACCOUNT, true);
        hub.createAccount(poolId, LIABILITY_ACCOUNT, false);

        uint128 poolDecimals = (10 ** hubRegistry.decimals(USD_ID.raw())).toUint128();
        uint128 expenseDecimals = (10 ** hubRegistry.decimals(FEE_C2.raw())).toUint128();

        cv.updateHoldingAmount(poolId, scId, FEE_C2, 50 * expenseDecimals, D18.wrap(1e18), true, IS_SNAPSHOT, 0);

        assertEq(holdings.amount(poolId, scId, FEE_C2), 50 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_C2), 50 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 0 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 0 * poolDecimals);

        hub.initializeLiability(poolId, scId, FEE_C2, valuation, FEE_ACCOUNT, LIABILITY_ACCOUNT);

        assertEq(holdings.amount(poolId, scId, FEE_C2), 50 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_C2), 50 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 50 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 50 * poolDecimals);

        cv.updateHoldingAmount(poolId, scId, FEE_C2, 20 * expenseDecimals, D18.wrap(1e18), false, IS_SNAPSHOT, 1);

        assertEq(holdings.amount(poolId, scId, FEE_C2), 30 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_C2), 30 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 30 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 30 * poolDecimals);

        valuation.setPrice(poolId, scId, FEE_C2, d18(11, 10));
        hub.updateHoldingValue(poolId, scId, FEE_C2);

        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 33 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 33 * poolDecimals);

        valuation.setPrice(poolId, scId, FEE_C2, d18(8, 10));
        hub.updateHoldingValue(poolId, scId, FEE_C2);

        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 24 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 24 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testUpdateShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(true);

        cv.updateShares(poolId, scId, 100, true, IS_SNAPSHOT, 0);

        uint128 totalIssuance = shareClassManager.totalIssuance(poolId, scId);
        assertEq(totalIssuance, 100);

        cv.updateShares(poolId, scId, 45, false, IS_SNAPSHOT, 1);

        uint128 totalIssuance2 = shareClassManager.totalIssuance(poolId, scId);
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
        hub.updateSharePrice(poolId, scId, sharePrice, uint64(block.timestamp));
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

    function testTransferShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(true);
        vm.stopPrank();

        vm.mockCall(
            address(hubHandler.sender()),
            abi.encodeWithSignature(
                "sendExecuteTransferShares(uint16,uint64,bytes16,bytes32,uint128,uint128,address)",
                CHAIN_CP,
                poolId.raw(),
                scId.raw(),
                INVESTOR,
                100,
                0,
                REFUND
            ),
            abi.encode(0)
        );

        // Test that initiateTransferShares works correctly even before shares are issued
        vm.prank(address(messageProcessor));
        hubHandler.initiateTransferShares(
            CHAIN_CV, // originCentrifugeId
            CHAIN_CP, // targetCentrifugeId
            poolId,
            scId,
            INVESTOR, // receiver
            100, // amount
            0, // extraGasLimit
            REFUND
        );
    }
}
