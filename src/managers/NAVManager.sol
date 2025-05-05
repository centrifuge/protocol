// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {IHub} from "src/hub/interfaces/IHub.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

contract NAVManager is Auth {
    error InvalidShareClassCount();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    AccountId public immutable equityAccount;
    AccountId public immutable liabilityAccount;
    AccountId public immutable gainAccount;
    AccountId public immutable lossAccount;

    IHub public immutable hub;
    IAccounting public immutable accounting;
    IShareClassManager public immutable shareClassManager;

    AccountId internal assetAccount;
    AccountId internal expenseAccount;

    constructor(PoolId poolId_, ShareClassId scId_, IHub hub_, address deployer) Auth(deployer) {
        require(hub.shareClassManager().shareClassCount(poolId_) == 1, InvalidShareClassCount());

        poolId = poolId_;
        scId = scId_;
        hub = hub_;
        accounting = hub.accounting();
        shareClassManager = hub.shareClassManager();

        equityAccount = AccountId.wrap(1);
        liabilityAccount = AccountId.wrap(2);
        gainAccount = AccountId.wrap(3);
        lossAccount = AccountId.wrap(4);
        hub.createAccount(poolId, equityAccount, false);
        hub.createAccount(poolId, liabilityAccount, false);
        hub.createAccount(poolId, gainAccount, false);
        hub.createAccount(poolId, lossAccount, false);

        assetAccount = AccountId.wrap(5);
    }

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    function createHolding(AssetId assetId, IERC7726 valuation) external auth {
        hub.createAccount(poolId, assetAccount, true);
        hub.createHolding(poolId, scId, assetId, valuation, assetAccount, equityAccount, gainAccount, lossAccount);
        assetAccount = assetAccount.increment();
    }

    function createLiability(AssetId assetId, IERC7726 valuation) external auth {
        hub.createAccount(poolId, expenseAccount, true);
        hub.createLiability(poolId, scId, assetId, valuation, expenseAccount, liabilityAccount);
        expenseAccount = expenseAccount.increment();
    }

    //----------------------------------------------------------------------------------------------
    // Price updates
    //----------------------------------------------------------------------------------------------

    function updatePricePerShare() external {
        (D18 current, D18 stored) = navPoolPerShare();
        hub.updatePricePerShare(poolId, scId, current);
    }

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @dev NAV = equity + gain - loss - liability
    function netAssetValue() public view returns (D18) {
        return d18(accounting.accountValue(poolId, equityAccount)) + d18(accounting.accountValue(poolId, gainAccount))
            - d18(accounting.accountValue(poolId, lossAccount)) - d18(accounting.accountValue(poolId, liabilityAccount));
    }

    /// @dev Price = NAV / share class issuance
    function navPoolPerShare() public view returns (D18 current, D18 stored) {
        D18 nav = netAssetValue();
        (uint128 issuance, D18 prev) = shareClassManager.metrics(scId);

        current = netAssetValue / d18(issuance);
        stored = prev;
    }
}
