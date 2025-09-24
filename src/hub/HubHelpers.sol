// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IHub, AccountType} from "./interfaces/IHub.sol";
import {IAccounting} from "./interfaces/IAccounting.sol";
import {IHubHelpers} from "./interfaces/IHubHelpers.sol";
import {IHubRegistry} from "./interfaces/IHubRegistry.sol";
import {IHoldings, HoldingAccount} from "./interfaces/IHoldings.sol";
import {IShareClassManager} from "./interfaces/IShareClassManager.sol";

import {Auth} from "../misc/Auth.sol";
import {D18, d18} from "../misc/types/D18.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {AccountId} from "../common/types/AccountId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";
import {IHubMessageSender} from "../common/interfaces/IGatewaySenders.sol";
import {RequestMessageLib} from "../common/libraries/RequestMessageLib.sol";
import {RequestCallbackMessageLib} from "../common/libraries/RequestCallbackMessageLib.sol";

contract HubHelpers is Auth, IHubHelpers {
    using MathLib for uint256;
    using RequestMessageLib for *;
    using RequestCallbackMessageLib for *;

    IHoldings public immutable holdings;
    IAccounting public immutable accounting;
    IHubRegistry public immutable hubRegistry;
    IHubMessageSender public immutable sender;
    IShareClassManager public immutable shareClassManager;

    IHub public hub;

    constructor(
        IHoldings holdings_,
        IAccounting accounting_,
        IHubRegistry hubRegistry_,
        IHubMessageSender sender_,
        IShareClassManager shareClassManager_,
        address deployer
    ) Auth(deployer) {
        holdings = holdings_;
        accounting = accounting_;
        hubRegistry = hubRegistry_;
        sender = sender_;
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
    /// @notice Create credit & debit entries for the deposit or withdrawal of a holding.
    ///         This updates the asset/expense as well as the equity/liability accounts.
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

    /// @inheritdoc IHubHelpers
    /// @notice Create credit & debit entries for the increase or decrease in the value of a holding.
    ///         This updates the asset/expense as well as the gain/loss accounts.
    function updateAccountingValue(PoolId poolId, ShareClassId scId, AssetId assetId, bool isPositive, uint128 diff)
        external
        auth
    {
        if (diff == 0) return;

        accounting.unlock(poolId);

        // Save a diff=0 update gas cost
        if (isPositive) {
            if (holdings.isLiability(poolId, scId, assetId)) {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Liability)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Expense)), diff);
            } else {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Gain)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset)), diff);
            }
        } else {
            if (holdings.isLiability(poolId, scId, assetId)) {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Expense)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Liability)), diff);
            } else {
                accounting.addCredit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Asset)), diff);
                accounting.addDebit(holdings.accountId(poolId, scId, assetId, uint8(AccountType.Loss)), diff);
            }
        }

        accounting.lock();
    }

    //----------------------------------------------------------------------------------------------
    //  View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IHubHelpers
    function holdingAccounts(
        AccountId assetAccount,
        AccountId equityAccount,
        AccountId gainAccount,
        AccountId lossAccount
    ) external pure returns (HoldingAccount[] memory) {
        HoldingAccount[] memory accounts = new HoldingAccount[](4);
        accounts[0] = HoldingAccount(assetAccount, uint8(AccountType.Asset));
        accounts[1] = HoldingAccount(equityAccount, uint8(AccountType.Equity));
        accounts[2] = HoldingAccount(gainAccount, uint8(AccountType.Gain));
        accounts[3] = HoldingAccount(lossAccount, uint8(AccountType.Loss));
        return accounts;
    }

    /// @inheritdoc IHubHelpers
    function liabilityAccounts(AccountId expenseAccount, AccountId liabilityAccount)
        external
        pure
        returns (HoldingAccount[] memory)
    {
        HoldingAccount[] memory accounts = new HoldingAccount[](2);
        accounts[0] = HoldingAccount(expenseAccount, uint8(AccountType.Expense));
        accounts[1] = HoldingAccount(liabilityAccount, uint8(AccountType.Liability));
        return accounts;
    }

    /// @inheritdoc IHubHelpers
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18) {
        // Assume price of 1.0 if the holding is not initialized yet
        if (!holdings.isInitialized(poolId, scId, assetId)) return d18(1, 1);

        // NOTE: We assume symmetric prices are provided by holdings valuation
        IValuation valuation = holdings.valuation(poolId, scId, assetId);

        // Retrieve amount of 1 asset unit in pool currency
        AssetId poolCurrency = hubRegistry.currency(poolId);
        uint128 assetUnitAmount = (10 ** hubRegistry.decimals(assetId.raw())).toUint128();
        uint128 poolUnitAmount = (10 ** hubRegistry.decimals(poolCurrency.raw())).toUint128();
        uint128 poolAmountPerAsset = valuation.getQuote(poolId, scId, assetId, assetUnitAmount);

        // Retrieve price by normalizing by pool denomination
        return d18(poolAmountPerAsset, poolUnitAmount);
    }
}
