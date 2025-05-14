// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IHubGatewayHandler} from "src/common/interfaces/IGatewayHandlers.sol";
import {IPoolMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IHubGuardianActions} from "src/common/interfaces/IGuardianActions.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHoldings, HoldingAccount} from "src/hub/interfaces/IHoldings.sol";
import {IHub, AccountType} from "src/hub/interfaces/IHub.sol";

contract HubHelpers is Auth {
    using MathLib for uint256;

    IHub public immutable hub;
    IHoldings public immutable holdings;
    IHubRegistry public immutable hubRegistry;

    constructor(IHub hub_, IHoldings holdings_, IHubRegistry hubRegistry_, address deployer) Auth(deployer) {
        hub = hub_;
        holdings = holdings_;
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    //  Auth methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHub
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        auth
        returns (uint128 totalPayoutShareAmount, uint128 totalPaymentAssetAmount, uint128 cancelledAssetAmount)
    {
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelled, bool canClaimAgain) =
                hub.claimDeposit(poolId, scId, investor, assetId);

            totalPayoutShareAmount += payoutShareAmount;
            totalPaymentAssetAmount += paymentAssetAmount;

            // Should be written at most once with non-zero amount iff the last claimable epoch was processed and
            // the user had a pending cancellation
            // NOTE: Purposely delaying corresponding message dispatch after deposit fulfillment message
            if (cancelled > 0) {
                cancelledAssetAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }
    }

    /// @inheritdoc IHub
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        auth
        returns (uint128 totalPayoutAssetAmount, uint128 totalPaymentShareAmount, uint128 cancelledShareAmount)
    {
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelled, bool canClaimAgain) =
                hub.claimRedeem(poolId, scId, investor, assetId);

            totalPayoutAssetAmount += payoutAssetAmount;
            totalPaymentShareAmount += paymentShareAmount;

            // Should be written at most once with non-zero amount iff the last claimable epoch was processed and
            // the user had a pending cancellation
            // NOTE: Purposely delaying corresponding message dispatch after redemption fulfillment message
            if (cancelled > 0) {
                cancelledShareAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }
    }

    /// @notice Create credit & debit entries for the increase or decrease in the holding amount
    function updateAccountingAmount(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        auth
    {
        if (diff == 0) return;

        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType debitAccountType = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType creditAccountType = isLiability ? AccountType.Liability : AccountType.Equity;

        JournalEntry[] memory debits;
        JournalEntry[] memory credits;
        if (isPositive) {
            debits.push(JournalEntry(diff, holdings.accountId(poolId, scId, assetId, uint8(debitAccountType))));
            credits.push(JournalEntry(diff, holdings.accountId(poolId, scId, assetId, uint8(creditAccountType))));
        } else {
            debits.push(JournalEntry(diff, holdings.accountId(poolId, scId, assetId, uint8(creditAccountType))));
            credits.push(JournalEntry(diff, holdings.accountId(poolId, scId, assetId, uint8(debitAccountType))));
        }

        hub.updateJournal(poolId, debits, credits);
    }

    //----------------------------------------------------------------------------------------------
    //  View methods
    //----------------------------------------------------------------------------------------------

    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18) {
        AssetId poolCurrency = hubRegistry.currency(poolId);
        // NOTE: We assume symmetric prices are provided by holdings valuation
        IERC7726 valuation = holdings.valuation(poolId, scId, assetId);

        // Retrieve amount of 1 asset unit in pool currency
        uint128 assetUnitAmount = (10 ** hubRegistry.decimals(assetId.raw())).toUint128();
        uint128 poolUnitAmount = (10 ** hubRegistry.decimals(poolCurrency.raw())).toUint128();
        uint128 poolAmountPerAsset =
            valuation.getQuote(assetUnitAmount, assetId.addr(), poolCurrency.addr()).toUint128();

        // Retrieve price by normalizing by pool denomination
        return d18(poolAmountPerAsset, poolUnitAmount);
    }
}
