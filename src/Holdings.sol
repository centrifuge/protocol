// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {newItemId, ItemId} from "src/types/ItemId.sol";

import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

import {MathLib} from "src/libraries/MathLib.sol";

import {Auth} from "src/Auth.sol";

import "forge-std/Test.sol";

struct Item {
    ShareClassId scId;
    AssetId assetId;
    IERC7726 valuation;
    uint128 assetAmount;
    uint128 assetAmountValue;
    bool alive;
}

contract Holdings is Auth, IHoldings {
    using MathLib for uint256; // toInt128()

    mapping(PoolId => Item[]) public item;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => ItemId))) public itemId;
    mapping(PoolId => mapping(ItemId => mapping(uint8 kind => AccountId))) public accountId;

    IPoolRegistry immutable poolRegistry;

    constructor(address deployer, IPoolRegistry poolRegistry_) Auth(deployer) {
        poolRegistry = poolRegistry_;
    }

    /// @inheritdoc IItemManager
    function create(PoolId poolId, IERC7726 valuation_, AccountId[] memory accounts, bytes calldata data)
        external
        auth
    {
        require(poolRegistry.exists(poolId), IPoolRegistry.NonExistingPool(poolId));
        require(address(valuation_) != address(0), WrongValuation());

        (ShareClassId scId, AssetId assetId) = abi.decode(data, (ShareClassId, AssetId));

        console.log(ShareClassId.unwrap(scId));
        console.log(AssetId.unwrap(assetId));

        require(!scId.isNull(), WrongShareClassId());
        require(!assetId.isNull(), WrongAssetId());

        ItemId itemId_ = newItemId(item[poolId].length);
        itemId[poolId][scId][assetId] = itemId_;
        item[poolId].push(Item(scId, assetId, valuation_, 0, 0, true));

        for (uint256 i = 0; i < accounts.length; i++) {
            AccountId accountId_ = accounts[i];
            accountId[poolId][itemId_][accountId_.kind()] = accountId_;
        }

        emit CreatedItem(poolId, itemId_, valuation_);
    }

    /// @inheritdoc IItemManager
    function close(PoolId poolId, ItemId itemId_, bytes calldata /*data*/ ) external auth {
        Item storage item_ = item[poolId][itemId_.index()];
        require(!item_.assetId.isNull(), ItemNotFound());

        item_.alive = false;
        itemId[poolId][item_.scId][item_.assetId] = ItemId.wrap(0);

        emit ClosedItem(poolId, itemId_);
    }

    /// @inheritdoc IItemManager
    function increase(PoolId poolId, ItemId itemId_, IERC7726 valuation_, uint128 amount)
        external
        auth
        returns (uint128 amountValue)
    {
        require(address(valuation_) != address(0), WrongValuation());

        Item storage item_ = item[poolId][itemId_.index()];
        require(!item_.assetId.isNull(), ItemNotFound());
        address poolCurrency = address(poolRegistry.currency(poolId));

        amountValue = uint128(valuation_.getQuote(amount, AssetId.unwrap(item_.assetId), poolCurrency));

        item_.assetAmount += amount;
        item_.assetAmountValue += amountValue;

        emit ItemIncreased(poolId, itemId_, valuation_, amount, amountValue);
    }

    /// @inheritdoc IItemManager
    function decrease(PoolId poolId, ItemId itemId_, IERC7726 valuation_, uint128 amount)
        external
        auth
        returns (uint128 amountValue)
    {
        require(address(valuation_) != address(0), WrongValuation());

        Item storage item_ = item[poolId][itemId_.index()];
        require(!item_.assetId.isNull(), ItemNotFound());
        address poolCurrency = address(poolRegistry.currency(poolId));

        amountValue = uint128(valuation_.getQuote(amount, AssetId.unwrap(item_.assetId), poolCurrency));

        item_.assetAmount -= amount;
        item_.assetAmountValue -= amountValue;

        emit ItemDecreased(poolId, itemId_, valuation_, amount, amountValue);
    }

    /// @inheritdoc IItemManager
    function update(PoolId poolId, ItemId itemId_) external auth returns (int128 diff) {
        Item storage item_ = item[poolId][itemId_.index()];
        require(!item_.assetId.isNull(), ItemNotFound());

        address poolCurrency = address(poolRegistry.currency(poolId));

        uint128 currentAmountValue =
            uint128(item_.valuation.getQuote(item_.assetAmount, AssetId.unwrap(item_.assetId), poolCurrency));

        diff = currentAmountValue > item_.assetAmountValue
            ? uint256(currentAmountValue - item_.assetAmountValue).toInt128()
            : -uint256(item_.assetAmountValue - currentAmountValue).toInt128();

        item_.assetAmountValue = currentAmountValue;

        emit ItemUpdated(poolId, itemId_, diff);
    }

    /// @inheritdoc IItemManager
    function increaseInterest(PoolId, /*poolId*/ ItemId, /*itemId_*/ uint128 /*interestAmount*/ ) external pure {
        revert("unsupported");
    }

    /// @inheritdoc IItemManager
    function decreaseInterest(PoolId, /*poolId*/ ItemId, /*itemId_*/ uint128 /*interestAmount*/ ) external pure {
        revert("unsupported");
    }

    /// @inheritdoc IItemManager
    function itemValue(PoolId poolId, ItemId itemId_) external view returns (uint128 value) {
        return item[poolId][itemId_.index()].assetAmountValue;
    }

    /// @inheritdoc IItemManager
    function valuation(PoolId poolId, ItemId itemId_) external view returns (IERC7726) {
        return item[poolId][itemId_.index()].valuation;
    }

    /// @inheritdoc IItemManager
    function updateValuation(PoolId poolId, ItemId itemId_, IERC7726 valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());

        Item storage item_ = item[poolId][itemId_.index()];
        require(!item_.assetId.isNull(), ItemNotFound());

        item_.valuation = valuation_;
    }

    /// @inheritdoc IItemManager
    function setAccountId(PoolId poolId, ItemId itemId_, AccountId accountId_) external auth {
        require(!item[poolId][itemId_.index()].assetId.isNull(), ItemNotFound());

        accountId[poolId][itemId_][accountId_.kind()] = accountId_;

        emit AccountIdSet(poolId, itemId_, accountId_);
    }

    /// @inheritdoc IHoldings
    function itemIdFromAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId) {
        return itemId[poolId][scId][assetId];
    }

    /// @inheritdoc IHoldings
    function itemIdToAsset(PoolId poolId, ItemId itemId_) external view returns (ShareClassId scId, AssetId assetId) {
        Item storage item_ = item[poolId][itemId_.index()];
        return (item_.scId, item_.assetId);
    }
}
