// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AccountId} from "src/types/Domain.sol";
import {IAccountingItemManager} from "src/interfaces/IAccountingItemManager.sol";
import {Auth} from "src/Auth.sol";

contract AccountingItemManager is Auth, IAccountingItemManager {
    mapping(PoolId => mapping(ItemId => Accounts)) public accounts;

    constructor(address deployer) Auth(deployer) {}

    function setItemAccounts(PoolId poolId, ItemId itemId, Accounts calldata itemAccounts_) external auth {
        accounts[poolId][itemId] = itemAccounts_;
    }

    function itemAccounts(PoolId poolId, ItemId itemId) external view returns (Accounts memory) {
        return accounts[poolId][itemId];
    }
}
