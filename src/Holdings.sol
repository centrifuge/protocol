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

contract Holdings is Auth, IHoldings {
    using MathLib for uint256; // toInt128()

    struct Item {
        ShareClassId scId;
        AssetId assetId;
        IERC7726 valuation;
        uint128 assetAmount;
        uint128 assetAmountValue;
    }

    mapping(PoolId => mapping(AssetId => bool)) public isAssetAllowed;
    mapping(PoolId => Item[]) public item;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => ItemId))) public itemId;
    mapping(PoolId => mapping(ItemId => mapping(uint8 kind => AccountId))) public accountId;

    IPoolRegistry public poolRegistry;

    constructor(IPoolRegistry poolRegistry_, address deployer) Auth(deployer) {
        poolRegistry = poolRegistry_;
    }

    /// @inheritdoc IHoldings
    function file(bytes32 what, address data) external auth {
        if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else revert FileUnrecognizedWhat();

        emit File(what, data);
    }

    /// @inheritdoc IHoldings
    function allowAsset(PoolId poolId, AssetId assetId, bool isAllow) external auth {
        require(!assetId.isNull(), WrongAssetId());

        isAssetAllowed[poolId][assetId] = isAllow;

        emit AllowedAsset(poolId, assetId, isAllow);
    }

    /// @inheritdoc IItemManager
    /// @param data Expect a (ShareClassId, AssetId) encoded.
    function create(PoolId poolId, IERC7726 valuation_, AccountId[] memory accounts, bytes calldata data)
        external
        auth
        returns (ItemId itemId_)
    {
        (ShareClassId scId, AssetId assetId) = abi.decode(data, (ShareClassId, AssetId));

        require(address(valuation_) != address(0), WrongValuation());
        require(!scId.isNull(), WrongShareClassId());
        require(isAssetAllowed[poolId][assetId], WrongAssetId());

        itemId_ = newItemId(item[poolId].length);
        item[poolId].push(Item(scId, assetId, valuation_, 0, 0));
        itemId[poolId][scId][assetId] = itemId_;

        for (uint256 i; i < accounts.length; i++) {
            AccountId accountId_ = accounts[i];
            accountId[poolId][itemId_][accountId_.kind()] = accountId_;
        }

        emit CreatedItem(poolId, itemId_, valuation_);
    }

    /// @inheritdoc IItemManager
    function increase(PoolId poolId, ItemId itemId_, IERC7726 valuation_, uint128 amount)
        external
        auth
        returns (uint128 amountValue)
    {
        require(address(valuation_) != address(0), WrongValuation());
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        Item storage item_ = item[poolId][itemId_.index()];
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
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        Item storage item_ = item[poolId][itemId_.index()];
        address poolCurrency = address(poolRegistry.currency(poolId));

        amountValue = uint128(valuation_.getQuote(amount, AssetId.unwrap(item_.assetId), poolCurrency));

        item_.assetAmount -= amount;
        item_.assetAmountValue -= amountValue;

        emit ItemDecreased(poolId, itemId_, valuation_, amount, amountValue);
    }

    /// @inheritdoc IItemManager
    function update(PoolId poolId, ItemId itemId_) external auth returns (int128 diffValue) {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        Item storage item_ = item[poolId][itemId_.index()];
        address poolCurrency = address(poolRegistry.currency(poolId));
        uint128 currentAmountValue =
            uint128(item_.valuation.getQuote(item_.assetAmount, AssetId.unwrap(item_.assetId), poolCurrency));

        diffValue = currentAmountValue > item_.assetAmountValue
            ? uint256(currentAmountValue - item_.assetAmountValue).toInt128()
            : -uint256(item_.assetAmountValue - currentAmountValue).toInt128();

        item_.assetAmountValue = currentAmountValue;

        emit ItemUpdated(poolId, itemId_, diffValue);
    }

    /// @inheritdoc IItemManager
    function updateValuation(PoolId poolId, ItemId itemId_, IERC7726 valuation_) external auth {
        require(address(valuation_) != address(0), WrongValuation());
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        item[poolId][itemId_.index()].valuation = valuation_;

        emit ValuationUpdated(poolId, itemId_, valuation_);
    }

    /// @inheritdoc IItemManager
    function setAccountId(PoolId poolId, ItemId itemId_, AccountId accountId_) external auth {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        accountId[poolId][itemId_][accountId_.kind()] = accountId_;

        emit AccountIdSet(poolId, itemId_, accountId_.kind(), accountId_);
    }

    /// @inheritdoc IItemManager
    function itemValue(PoolId poolId, ItemId itemId_) external view returns (uint128 value) {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        return item[poolId][itemId_.index()].assetAmountValue;
    }

    /// @inheritdoc IItemManager
    function itemAmount(PoolId poolId, ItemId itemId_) external view returns (uint128 amount) {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        return item[poolId][itemId_.index()].assetAmount;
    }

    /// @inheritdoc IItemManager
    function valuation(PoolId poolId, ItemId itemId_) external view returns (IERC7726) {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        return item[poolId][itemId_.index()].valuation;
    }

    /// @inheritdoc IHoldings
    function itemProperties(PoolId poolId, ItemId itemId_) external view returns (ShareClassId scId, AssetId assetId) {
        require(itemId_.index() < item[poolId].length, ItemNotFound());

        Item storage item_ = item[poolId][itemId_.index()];
        return (item_.scId, item_.assetId);
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
    function close(PoolId, /*poolId*/ ItemId, /*itemId_*/ bytes calldata /*data*/ ) external pure {
        revert("unsupported");
    }
}
