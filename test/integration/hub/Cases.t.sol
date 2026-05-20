// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AccountId} from "../../../src/core/types/AccountId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";

contract TestCases is CentrifugeIntegrationTest {
    using MathLib for *;

    bool constant IS_SNAPSHOT = true;

    address immutable FM = makeAddr("FM");

    AccountId constant ASSET_USDC_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);
    AccountId constant ASSET_EUR_STABLE_ACCOUNT = AccountId.wrap(0x05);
    AccountId constant FEE_ACCOUNT = AccountId.wrap(0x06);
    AccountId constant LIABILITY_ACCOUNT = AccountId.wrap(0x07);

    AssetId immutable USDC_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable EUR_STABLE_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 2);
    AssetId immutable FEE_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 3);

    function setUp() public virtual override {
        super.setUp();

        vm.deal(FM, 1 ether);

        vm.startPrank(address(root));
        hubRegistry.registerAsset(USDC_ID, 6);
        hubRegistry.registerAsset(EUR_STABLE_ID, 12);
        vm.stopPrank();
    }

    function _assertEqAccountValue(PoolId poolId, AccountId accountId, bool expectedIsPositive, uint128 expectedValue)
        internal
        view
    {
        (bool isPositive, uint128 value) = accounting.accountValue(poolId, accountId);
        assertEq(isPositive, expectedIsPositive, "Mismatch: Accounting.accountValue - isPositive");
        assertEq(value, expectedValue, "Mismatch: Accounting.accountValue - value");
    }

    /// forge-config: default.isolate = true
    function testPoolCreation(bool withInitialization) public returns (PoolId poolId, ShareClassId scId) {
        poolId = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(poolId, FM, USD_ID);

        scId = shareClassManager.previewNextShareClassId(poolId);
        bytes32 salt = bytes32(bytes8(poolId.raw()));

        vm.startPrank(FM);
        hub.addShareClass(poolId, "ExampleName", "ExampleSymbol", salt);
        hub.createAccount(poolId, ASSET_USDC_ACCOUNT, true);
        hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        hub.createAccount(poolId, GAIN_ACCOUNT, false);
        hub.createAccount(poolId, LOSS_ACCOUNT, true);
        hub.createAccount(poolId, ASSET_EUR_STABLE_ACCOUNT, true);
        if (withInitialization) {
            valuation.setPrice(poolId, scId, USDC_ID, d18(1, 1));
            hub.initializeHolding(
                poolId, scId, USDC_ID, valuation, ASSET_USDC_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
            );
            hub.initializeHolding(
                poolId,
                scId,
                EUR_STABLE_ID,
                valuation,
                ASSET_EUR_STABLE_ACCOUNT,
                EQUITY_ACCOUNT,
                GAIN_ACCOUNT,
                LOSS_ACCOUNT
            );
        }
        vm.stopPrank();
    }

    /// forge-config: default.isolate = true
    function testUpdateHolding() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(false);
        uint128 poolDecimals = (10 ** hubRegistry.decimals(USD_ID.raw())).toUint128();
        uint128 assetDecimals = (10 ** hubRegistry.decimals(USDC_ID.raw())).toUint128();

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            LOCAL_CENTRIFUGE_ID, poolId, scId, USDC_ID, 1000 * assetDecimals, D18.wrap(1e18), true, IS_SNAPSHOT, 0
        );

        assertEq(holdings.amount(poolId, scId, USDC_ID), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_ID), 1000 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        vm.prank(FM);
        hub.initializeHolding(
            poolId, scId, USDC_ID, valuation, ASSET_USDC_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );

        assertEq(holdings.amount(poolId, scId, USDC_ID), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_ID), 1000 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 1000 * poolDecimals);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 1000 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            LOCAL_CENTRIFUGE_ID, poolId, scId, USDC_ID, 600 * assetDecimals, D18.wrap(1e18), false, IS_SNAPSHOT, 1
        );

        assertEq(holdings.amount(poolId, scId, USDC_ID), 400 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_ID), 400 * poolDecimals);
        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 0);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        valuation.setPrice(poolId, scId, USDC_ID, d18(11, 10));
        vm.prank(FM);
        hub.updateHoldingValue(poolId, scId, USDC_ID);

        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 440 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 40 * poolDecimals);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 0);

        valuation.setPrice(poolId, scId, USDC_ID, d18(8, 10));
        vm.prank(FM);
        hub.updateHoldingValue(poolId, scId, USDC_ID);

        _assertEqAccountValue(poolId, ASSET_USDC_ACCOUNT, true, 320 * poolDecimals);
        _assertEqAccountValue(poolId, EQUITY_ACCOUNT, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, GAIN_ACCOUNT, true, 40 * poolDecimals);
        _assertEqAccountValue(poolId, LOSS_ACCOUNT, true, 120 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testUpdateLiability() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(false);

        vm.prank(address(root));
        hubRegistry.registerAsset(FEE_ID, 18);

        vm.startPrank(FM);
        hub.createAccount(poolId, FEE_ACCOUNT, true);
        hub.createAccount(poolId, LIABILITY_ACCOUNT, false);
        vm.stopPrank();

        uint128 poolDecimals = (10 ** hubRegistry.decimals(USD_ID.raw())).toUint128();
        uint128 expenseDecimals = (10 ** hubRegistry.decimals(FEE_ID.raw())).toUint128();

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            LOCAL_CENTRIFUGE_ID, poolId, scId, FEE_ID, 50 * expenseDecimals, D18.wrap(1e18), true, IS_SNAPSHOT, 0
        );

        assertEq(holdings.amount(poolId, scId, FEE_ID), 50 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_ID), 50 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 0 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 0 * poolDecimals);

        vm.prank(FM);
        hub.initializeLiability(poolId, scId, FEE_ID, valuation, FEE_ACCOUNT, LIABILITY_ACCOUNT);

        assertEq(holdings.amount(poolId, scId, FEE_ID), 50 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_ID), 50 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 50 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 50 * poolDecimals);

        vm.prank(address(messageDispatcher));
        hubHandler.updateHoldingAmount(
            LOCAL_CENTRIFUGE_ID, poolId, scId, FEE_ID, 20 * expenseDecimals, D18.wrap(1e18), false, IS_SNAPSHOT, 1
        );

        assertEq(holdings.amount(poolId, scId, FEE_ID), 30 * expenseDecimals);
        assertEq(holdings.value(poolId, scId, FEE_ID), 30 * poolDecimals);
        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 30 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 30 * poolDecimals);

        valuation.setPrice(poolId, scId, FEE_ID, d18(11, 10));
        vm.prank(FM);
        hub.updateHoldingValue(poolId, scId, FEE_ID);

        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 33 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 33 * poolDecimals);

        valuation.setPrice(poolId, scId, FEE_ID, d18(8, 10));
        vm.prank(FM);
        hub.updateHoldingValue(poolId, scId, FEE_ID);

        _assertEqAccountValue(poolId, FEE_ACCOUNT, true, 24 * poolDecimals);
        _assertEqAccountValue(poolId, LIABILITY_ACCOUNT, true, 24 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testUpdateShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation(true);

        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(LOCAL_CENTRIFUGE_ID, poolId, scId, 100, true, IS_SNAPSHOT, 0);

        uint128 totalIssuance = shareClassManager.totalIssuance(poolId, scId);
        assertEq(totalIssuance, 100);

        vm.prank(address(messageDispatcher));
        hubHandler.updateShares(LOCAL_CENTRIFUGE_ID, poolId, scId, 45, false, IS_SNAPSHOT, 1);

        uint128 totalIssuance2 = shareClassManager.totalIssuance(poolId, scId);
        assertEq(totalIssuance2, 55);
    }
}
