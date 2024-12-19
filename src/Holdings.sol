// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AccountId, AssetId, ShareClassId} from "src/types/Domain.sol";

import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

import {MathLib} from "src/libraries/MathLib.sol";

import {AccountingItemManager} from "src/AccountingItemManager.sol";
import {Auth} from "src/Auth.sol";

struct Item {
    ShareClassId scId;
    AssetId assetId;
    IERC7726 valuation;
    uint128 assetAmount;
    uint128 assetAmountValue;
}

contract Holdings is AccountingItemManager, IHoldings {
    using MathLib for uint256;

    mapping(PoolId => mapping(ItemId => Item)) public items;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => ItemId))) public itemIds;
    mapping(PoolId => uint32) lastItemId;

    IPoolRegistry immutable poolRegistry;

    constructor(address deployer, IPoolRegistry poolRegistry_) AccountingItemManager(deployer) {
        poolRegistry = poolRegistry_;
        // TODO: should we initialize the accounts from AccountingItemManager here?
    }

    /// @inheritdoc IItemManager
    function create(PoolId poolId, IERC7726 valuation_, bytes calldata data) external auth {
        (ShareClassId scId, AssetId assetId) = abi.decode(data, (ShareClassId, AssetId));

        ItemId itemId = ItemId.wrap(++lastItemId[poolId]);
        itemIds[poolId][scId][assetId] = itemId;
        items[poolId][itemId] = Item(scId, assetId, valuation_, 0, 0);
    }

    /// @inheritdoc IItemManager
    function close(PoolId poolId, ItemId itemId, bytes calldata /*data*/ ) external auth {
        Item storage item = items[poolId][itemId];
        itemIds[poolId][item.scId][item.assetId] = ItemId.wrap(0);
        delete items[poolId][itemId];
    }

    /// @inheritdoc IItemManager
    function increase(PoolId poolId, ItemId itemId, uint128 amount) external auth returns (uint128 amountValue) {
        Item storage item = items[poolId][itemId];
        address poolCurrency = address(poolRegistry.poolCurrencies(poolId));

        amountValue = uint128(item.valuation.getQuote(amount, AssetId.unwrap(item.assetId), poolCurrency));

        item.assetAmount += amount;
        item.assetAmountValue += amountValue;
    }

    /// @inheritdoc IItemManager
    function decrease(PoolId poolId, ItemId itemId, uint128 amount) external auth returns (uint128 amountValue) {
        Item storage item = items[poolId][itemId];
        address poolCurrency = address(poolRegistry.poolCurrencies(poolId));

        amountValue = uint128(item.valuation.getQuote(amount, AssetId.unwrap(item.assetId), poolCurrency));

        item.assetAmount -= amount;
        item.assetAmountValue -= amountValue;
    }

    /// @inheritdoc IItemManager
    function update(PoolId poolId, ItemId itemId) external auth returns (int128 diff) {
        Item storage item = items[poolId][itemId];

        address poolCurrency = address(poolRegistry.poolCurrencies(poolId));

        uint128 currentAmountValue =
            uint128(item.valuation.getQuote(item.assetAmount, AssetId.unwrap(item.assetId), poolCurrency));

        diff = currentAmountValue > item.assetAmountValue
            ? uint256(currentAmountValue - item.assetAmountValue).toInt128()
            : -uint256(item.assetAmountValue - currentAmountValue).toInt128();

        item.assetAmountValue = currentAmountValue;
    }

    /// @inheritdoc IItemManager
    function decreaseInterest(PoolId, /*poolId*/ ItemId, /*itemId*/ uint128 /*amount*/ ) external pure {
        revert("unsupported");
    }

    function increaseInterest(PoolId, /*poolId*/ ItemId, /*itemId*/ uint128 /*amount*/ ) external pure {
        revert("unsupported");
    }

    /// @inheritdoc IItemManager
    function itemValue(PoolId poolId, ItemId itemId) external view returns (uint128 value) {
        return items[poolId][itemId].assetAmountValue;
    }

    /// @inheritdoc IItemManager
    function valuation(PoolId poolId, ItemId itemId) external view returns (IERC7726) {
        return items[poolId][itemId].valuation;
    }

    /// @inheritdoc IItemManager
    function updateValuation(PoolId poolId, ItemId itemId, IERC7726 valuation_) external auth {
        items[poolId][itemId].valuation = valuation_;
    }

    /// @inheritdoc IHoldings
    function itemIdFromAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (ItemId) {
        return itemIds[poolId][scId][assetId];
    }

    /// @inheritdoc IHoldings
    function itemIdToAsset(PoolId poolId, ItemId itemId) external view returns (ShareClassId scId, AssetId assetId) {
        Item storage item = items[poolId][itemId];
        return (item.scId, item.assetId);
    }
}
