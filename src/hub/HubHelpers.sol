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

import {IHubHelpers} from "src/hub/interfaces/IHubHelpers.sol";
import {IAccounting, JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {IHoldings, HoldingAccount} from "src/hub/interfaces/IHoldings.sol";
import {IHub, AccountType} from "src/hub/interfaces/IHub.sol";

contract HubHelpers is Auth, IHubHelpers {
    using MathLib for uint256;

    IHoldings public immutable holdings;
    IAccounting public immutable accounting;
    IHubRegistry public immutable hubRegistry;
    IShareClassManager public immutable shareClassManager;

    IHub public hub;

    constructor(
        IHoldings holdings_,
        IAccounting accounting_,
        IHubRegistry hubRegistry_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) {
        holdings = holdings_;
        accounting = accounting_;
        hubRegistry = hubRegistry_;
        shareClassManager = shareClassManager_;
    }

    /// @inheritdoc IHubHelpers
    function file(bytes32 what, address data) external auth {
        if (what == "hub") hub = IHub(data);
        else revert FileUnrecognizedParam();

        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    //  Auth methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubHelpers
    function notifyDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        auth
        returns (uint128 totalPayoutShareAmount, uint128 totalPaymentAssetAmount, uint128 cancelledAssetAmount)
    {
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelled, bool canClaimAgain) =
                shareClassManager.claimDeposit(poolId, scId, investor, assetId);

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

    /// @inheritdoc IHubHelpers
    function notifyRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint32 maxClaims)
        external
        auth
        returns (uint128 totalPayoutAssetAmount, uint128 totalPaymentShareAmount, uint128 cancelledShareAmount)
    {
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelled, bool canClaimAgain) =
                shareClassManager.claimRedeem(poolId, scId, investor, assetId);

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

        accounting.unlock(poolId);

        bool isLiability = holdings.isLiability(poolId, scId, assetId);
        AccountType debitAccountType = isLiability ? AccountType.Expense : AccountType.Asset;
        AccountType creditAccountType = isLiability ? AccountType.Liability : AccountType.Equity;

        if (isPositive) {
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), diff);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), diff);
        } else {
            accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(creditAccountType)), diff);
            accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(debitAccountType)), diff);
        }

        accounting.lock();
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
