// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "test/hub/integration/BaseTest.sol";
import {TransientValuation} from "test/misc/mocks/TransientValuation.sol";

contract TestCases is BaseTest {
    using CastLib for string;
    using CastLib for bytes32;
    using MathLib for *;
    using MessageLib for *;
    using PricingLib for *;

    TransientValuation transientValuation;

    function setUp() public override {
        super.setUp();
        transientValuation = new TransientValuation(hubRegistry);
    }

    /// forge-config: default.isolate = true
    function testPoolCreation() public returns (PoolId poolId, ShareClassId scId) {
        cv.registerAsset(USDC_C2, 6);
        cv.registerAsset(EUR_STABLE_C2, 12);

        poolId = hubRegistry.poolId(CHAIN_CP, 1);
        vm.prank(ADMIN);
        guardian.createPool(poolId, FM, USD);

        scId = shareClassManager.previewNextShareClassId(poolId);

        vm.startPrank(FM);
        hub.setPoolMetadata(poolId, bytes("Testing pool"));
        hub.addShareClass(poolId, SC_NAME, SC_SYMBOL, SC_SALT);
        hub.notifyPool{value: GAS}(poolId, CHAIN_CV);
        hub.notifyShareClass{value: GAS}(poolId, scId, CHAIN_CV, SC_HOOK);
        hub.createAccount(poolId, AccountId.wrap(0x01), true);
        hub.createAccount(poolId, AccountId.wrap(0x02), false);
        hub.createAccount(poolId, AccountId.wrap(0x03), false);
        hub.createAccount(poolId, AccountId.wrap(0x04), false);
        hub.createAccount(poolId, AccountId.wrap(0x05), true);
        hub.createHolding(
            poolId,
            scId,
            USDC_C2,
            identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );
        hub.createHolding(
            poolId,
            scId,
            EUR_STABLE_C2,
            transientValuation,
            AccountId.wrap(0x05),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );
        hub.updateContract{value: GAS}(
            poolId,
            scId,
            CHAIN_CV,
            bytes32("target"),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: bytes32("factory"),
                assetId: USDC_C2.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );
        vm.stopPrank();

        assertEq(hubRegistry.metadata(poolId), "Testing pool");
        assertEq(shareClassManager.exists(poolId, scId), true);

        MessageLib.NotifyPool memory m0 = MessageLib.deserializeNotifyPool(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());

        MessageLib.NotifyShareClass memory m1 = MessageLib.deserializeNotifyShareClass(cv.lastMessages(1));
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.name, SC_NAME);
        assertEq(m1.symbol, SC_SYMBOL.toBytes32());
        assertEq(m1.decimals, 18);
        assertEq(m1.salt, SC_SALT);
        assertEq(m1.hook, SC_HOOK);

        MessageLib.UpdateContract memory m2 = MessageLib.deserializeUpdateContract(cv.lastMessages(2));
        assertEq(m2.scId, scId.raw());
        assertEq(m2.target, bytes32("target"));

        MessageLib.UpdateContractVaultUpdate memory m3 = MessageLib.deserializeUpdateContractVaultUpdate(m2.payload);
        assertEq(m3.assetId, USDC_C2.raw());
        assertEq(m3.vaultOrFactory, bytes32("factory"));
        assertEq(m3.kind, uint8(VaultUpdateKind.DeployAndLink));

        cv.resetMessages();
    }

    /// forge-config: default.isolate = true
    function testDeposit() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testPoolCreation();

        cv.requestDeposit(poolId, scId, USDC_C2, INVESTOR, INVESTOR_AMOUNT);

        vm.startPrank(FM);
        hub.approveDeposits{value: GAS}(
            poolId, scId, USDC_C2, shareClassManager.nowDepositEpoch(scId, USDC_C2), APPROVED_INVESTOR_AMOUNT
        );
        hub.issueShares(poolId, scId, USDC_C2, shareClassManager.nowIssueEpoch(scId, USDC_C2), NAV_PER_SHARE);
        vm.stopPrank();

        vm.prank(ANY);
        vm.deal(ANY, GAS);
        hub.notifyDeposit{value: GAS}(
            poolId, scId, USDC_C2, INVESTOR, shareClassManager.maxDepositClaims(scId, INVESTOR, USDC_C2)
        );

        assertEq(cv.messageCount(), 2);
        MessageLib.ApprovedDeposits memory m0 = MessageLib.deserializeApprovedDeposits(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.assetId, USDC_C2.raw());
        assertEq(m0.assetAmount, APPROVED_INVESTOR_AMOUNT);

        MessageLib.FulfilledDepositRequest memory m1 = MessageLib.deserializeFulfilledDepositRequest(cv.lastMessages(1));
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.investor, INVESTOR);
        assertEq(m1.assetId, USDC_C2.raw());
        assertEq(m1.assetAmount, APPROVED_INVESTOR_AMOUNT);
        assertEq(
            m1.shareAmount,
            PricingLib.convertWithPrice(
                APPROVED_INVESTOR_AMOUNT,
                hubRegistry.decimals(USDC_C2),
                hubRegistry.decimals(poolId),
                NAV_PER_SHARE.reciprocal()
            ).toUint128()
        );

        cv.resetMessages();
    }

    /// forge-config: default.isolate = true
    function testRedeem() public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = testDeposit();

        cv.requestRedeem(poolId, scId, USDC_C2, INVESTOR, SHARE_AMOUNT);

        uint128 revokedAssetAmount = PricingLib.convertWithPrice(
            APPROVED_SHARE_AMOUNT, hubRegistry.decimals(poolId), hubRegistry.decimals(USDC_C2), NAV_PER_SHARE
        ).toUint128();

        vm.startPrank(FM);
        hub.approveRedeems(
            poolId, scId, USDC_C2, shareClassManager.nowRedeemEpoch(scId, USDC_C2), APPROVED_SHARE_AMOUNT
        );
        hub.revokeShares{value: GAS}(
            poolId, scId, USDC_C2, shareClassManager.nowRevokeEpoch(scId, USDC_C2), NAV_PER_SHARE
        );
        vm.stopPrank();

        vm.prank(ANY);
        vm.deal(ANY, GAS);
        hub.notifyRedeem{value: GAS}(
            poolId, scId, USDC_C2, INVESTOR, shareClassManager.maxRedeemClaims(scId, INVESTOR, USDC_C2)
        );

        assertEq(cv.messageCount(), 2);

        MessageLib.RevokedShares memory m0 = MessageLib.deserializeRevokedShares(cv.lastMessages(0));
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.assetId, USDC_C2.raw());
        assertEq(m0.assetAmount, revokedAssetAmount);

        MessageLib.FulfilledRedeemRequest memory m1 = MessageLib.deserializeFulfilledRedeemRequest(cv.lastMessages(1));
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.investor, INVESTOR);
        assertEq(m1.assetId, USDC_C2.raw());
        assertEq(m1.assetAmount, revokedAssetAmount);
        assertEq(m1.shareAmount, APPROVED_SHARE_AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testCalUpdateHolding() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();
        uint128 poolDecimals = (10 ** hubRegistry.decimals(USD.raw())).toUint128();
        uint128 assetDecimals = (10 ** hubRegistry.decimals(USDC_C2.raw())).toUint128();

        AccountId equityAccount = holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.Equity));
        AccountId assetAccount = holdings.accountId(poolId, scId, USDC_C2, uint8(AccountType.Asset));

        cv.updateHoldingAmount(poolId, scId, USDC_C2, 1000 * assetDecimals, D18.wrap(1e18), true);

        assertEq(holdings.amount(poolId, scId, USDC_C2), 1000 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 1000 * poolDecimals);
        _assertEqAccountValue(poolId, equityAccount, true, 1000 * poolDecimals);
        _assertEqAccountValue(poolId, assetAccount, true, 1000 * poolDecimals);

        cv.updateHoldingAmount(poolId, scId, USDC_C2, 600 * assetDecimals, D18.wrap(1e18), false);

        assertEq(holdings.amount(poolId, scId, USDC_C2), 400 * assetDecimals);
        assertEq(holdings.value(poolId, scId, USDC_C2), 400 * poolDecimals);
        _assertEqAccountValue(poolId, assetAccount, true, 400 * poolDecimals);
        _assertEqAccountValue(poolId, equityAccount, true, 400 * poolDecimals);
    }

    /// forge-config: default.isolate = true
    function testCalUpdateShares() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();

        cv.updateShares(poolId, scId, 100, true);

        (uint128 totalIssuance,) = shareClassManager.metrics(scId);
        assertEq(totalIssuance, 100);

        cv.updateShares(poolId, scId, 45, false);

        (uint128 totalIssuance2,) = shareClassManager.metrics(scId);
        assertEq(totalIssuance2, 55);
    }

    function testNotifyPricePoolPerShare() public {
        (PoolId poolId, ShareClassId scId) = testPoolCreation();
        D18 sharePrice = d18(100, 1);
        D18 identityPrice = d18(1, 1);
        D18 poolPerEurPrice = d18(4, 1);
        AssetId poolCurrency = hubRegistry.currency(poolId);

        transientValuation.setPrice(EUR_STABLE_C2.addr(), poolCurrency.addr(), poolPerEurPrice);

        vm.startPrank(FM);
        hub.updatePricePerShare(poolId, scId, sharePrice);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, EUR_STABLE_C2);
        hub.notifyAssetPrice{value: GAS}(poolId, scId, USDC_C2);
        hub.notifySharePrice{value: GAS}(poolId, scId, CHAIN_CV);
        vm.stopPrank();

        assertEq(cv.messageCount(), 3);

        MessageLib.NotifyPricePoolPerShare memory m0 = MessageLib.deserializeNotifyPricePoolPerShare(cv.popMessage());
        assertEq(m0.poolId, poolId.raw());
        assertEq(m0.scId, scId.raw());
        assertEq(m0.price, sharePrice.raw(), "Share price mismatch");
        assertEq(m0.timestamp, block.timestamp.toUint64());

        MessageLib.NotifyPricePoolPerAsset memory m1 = MessageLib.deserializeNotifyPricePoolPerAsset(cv.popMessage());
        assertEq(m1.poolId, poolId.raw());
        assertEq(m1.scId, scId.raw());
        assertEq(m1.assetId, USDC_C2.raw());
        assertEq(m1.price, identityPrice.inner(), "USDC price mismatch");
        assertEq(m1.timestamp, block.timestamp.toUint64());

        MessageLib.NotifyPricePoolPerAsset memory m2 = MessageLib.deserializeNotifyPricePoolPerAsset(cv.popMessage());
        assertEq(m2.poolId, poolId.raw());
        assertEq(m2.scId, scId.raw());
        assertEq(m2.assetId, EUR_STABLE_C2.raw());
        assertEq(m2.price, poolPerEurPrice.inner(), "EUR price mismatch");
        assertEq(m2.timestamp, block.timestamp.toUint64());
    }
}
