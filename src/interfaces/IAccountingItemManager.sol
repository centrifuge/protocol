// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AccountId} from "src/types/Domain.sol";

// IAccountingItemManager is an interface all ItemManager should implement (mostly in the same way) to be able to be
// used in an IAccounting contract.
interface IAccountingItemManager {
    struct Accounts {
        AccountId asset;
        AccountId equity;
        AccountId loss;
        AccountId gain;
    }

    function setItemAccounts(PoolId poolId, ItemId itemId, Accounts calldata itemAccounts) external;
    function itemAccounts(PoolId poolId, ItemId itemId) external view returns (Accounts memory);
}
