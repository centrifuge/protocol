// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {RequestId} from "../../src/core/types/RequestId.sol";

import {IAsyncVault, IVaultEvents} from "../../src/vaults/interfaces/IAsyncVault.sol";

/// @dev Indexers read a request's outcome from the vault's `BucketSettled`, emitted when the hub's
///      settlement lands rather than when someone folds it. Every settlement kind, as the hub sends
///      it through the FeeRequestManager and OrderBook, emits it with the amounts it settled.
/// forge-config: default.isolate = true
contract VaultSettlementEventsTest is EndToEndFlows {
    function _setUpVault(bool sameChain) internal returns (IAsyncVault vault) {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vault = _deployVault();
    }

    function _expectSettle(IAsyncVault vault, RequestId requestId, bool isDeposit, uint128 a, uint128 s_, uint128 g)
        internal
    {
        vm.expectEmit(true, false, false, true, address(vault));
        emit IVaultEvents.BucketSettled(requestId.raw(), isDeposit, a, s_, g, g);
    }

    function testADepositFillEmitsSettleBucket(bool sameChain) public {
        IAsyncVault vault = _setUpVault(sameChain);
        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);

        _expectSettle(vault, requestId, true, USDC_AMOUNT_1, assetToShare(USDC_AMOUNT_1), 0);
        _fulfill(true, requestId, USDC_AMOUNT_1);
    }

    function testADepositCancellationEmitsSettleBucket(bool sameChain) public {
        IAsyncVault vault = _setUpVault(sameChain);
        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);

        _expectSettle(vault, requestId, true, 0, 0, USDC_AMOUNT_1);
        _cancel(true, requestId, USDC_AMOUNT_1);
    }

    function testARedeemFillEmitsSettleBucket(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _addMember(INVESTOR_A);
        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));

        _expectSettle(vault, requestId, false, shareToAsset(shares), shares, 0);
        _fulfill(false, requestId, shares);
    }

    function testARedeemCancellationEmitsSettleBucket(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _addMember(INVESTOR_A);
        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));

        _expectSettle(vault, requestId, false, 0, 0, shares);
        _cancel(false, requestId, shares);
    }
}
