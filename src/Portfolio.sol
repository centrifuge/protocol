// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import {Decimal18, d18} from "src/libraries/Decimal18.sol";
import {MathLib} from "src/libraries/MathLib.sol";

interface IERC6909 {
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);
}

interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}

interface IPoolRegistry {
    function currencyOfPool(PoolId poolId) external view returns (address currency);
}

interface ILinearAccrual {
    function increaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 increment)
        external
        returns (uint128 newNormalizedDebt);

    function decreaseNormalizedDebt(bytes32 rateId, uint128 prevNormalizedDebt, uint128 decrement)
        external
        returns (uint128 newNormalizedDebt);

    function renormalizeDebt(bytes32 rateId, uint256 newRateId, uint128 prevNormalizedDebt)
        external
        returns (uint128 newNormalizedDebt);
}

type PoolId is uint64;

type ItemId is uint32;

/// Required data to locate the collateral
struct Collateral {
    /// Contract where the collateral exists
    IERC6909 source;
    /// Identification of the collateral in that contract
    uint256 id;
}

function globalId(Collateral memory collateral) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encode(collateral.source, collateral.id)))));
}

using {globalId} for Collateral;

/// Struct used for user inputs and "static" item data
struct ItemInfo {
    /// The RWA used for this item as a collateral
    Collateral collateral;
    /// Fixed point rate
    bytes32 rateId;
    /// Fixed point number with the amount of asset hold by this item.
    /// Usually for Price valued items it will be > 1. Other valuations will normally set this value from 0-1.
    Decimal18 quantity;
    /// Valuation method
    IERC7726 valuation;
}

struct Item {
    /// Base info of this item
    ItemInfo info;
    /// A representation of the debt used by LinealAccrual to obtain the real debt
    uint128 normalizedDebt;
    /// Outstanding quantity
    Decimal18 outstandingQuantity;
}

function exists(Item storage item) view returns (bool) {
    return address(item.info.collateral.source) != address(0);
}

using {exists} for Item;

contract Portfolio {
    using MathLib for uint256;

    error ItemNotFound();
    error ItemCanNotBeClosed();
    error CollateralCanNotBeTransfered();

    event Create(PoolId, ItemId);
    event DebtIncreased(PoolId, ItemId, Decimal18 quantity);
    event DebtDecreased(PoolId, ItemId, Decimal18 quantity, uint128 interest);
    event TransferDebt(PoolId, ItemId from, ItemId to, Decimal18 quantity, uint128 interest);
    event Closed(PoolId, ItemId);

    mapping(PoolId => uint32 nonce) public itemNonces;
    mapping(PoolId => mapping(ItemId => Item)) public items;

    IPoolRegistry poolRegistry;
    ILinearAccrual linearAccrual;

    constructor(IPoolRegistry _poolRegistry, ILinearAccrual _linearAccrual) {
        poolRegistry = _poolRegistry;
        linearAccrual = _linearAccrual;
    }

    function create(PoolId poolId, ItemInfo calldata info) external {
        bool ok = info.collateral.source.transfer(address(this), info.collateral.id, 1);
        require(ok, CollateralCanNotBeTransfered());

        ItemId itemId = ItemId.wrap(itemNonces[poolId]++);
        items[poolId][itemId] = Item(info, 0, d18(0));

        emit Create(poolId, itemId);
    }

    function increaseDebt(PoolId poolId, ItemId itemId, Decimal18 quantity) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        uint128 price = this.getPrice(poolId, itemId);
        uint128 amount = quantity.mulInt(price);

        item.normalizedDebt = linearAccrual.increaseNormalizedDebt(item.info.rateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity + quantity;

        emit DebtIncreased(poolId, itemId, quantity);
    }

    function decreaseDebt(PoolId poolId, ItemId itemId, Decimal18 principalQuantity, uint128 interest) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        uint128 price = this.getPrice(poolId, itemId);
        uint128 amount = principalQuantity.mulInt(price) + interest;

        item.normalizedDebt = linearAccrual.decreaseNormalizedDebt(item.info.rateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity - principalQuantity;

        emit DebtDecreased(poolId, itemId, principalQuantity, interest);
    }

    function transferDebt(PoolId poolId, ItemId from, ItemId to, Decimal18 principal, uint128 interestPaid) external {
        //TODO: decreaseDebt(from) + increaseDebt(to)
    }

    function close(PoolId poolId, ItemId itemId) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());
        require(item.outstandingQuantity.inner() == 0, ItemCanNotBeClosed());

        // TODO: transfer back the collateral.
        delete items[poolId][itemId];

        emit Closed(poolId, itemId);
    }

    /// The price for one element of this item.
    function getPrice(PoolId poolId, ItemId itemId) external view returns (uint128 value) {
        Item storage item = items[poolId][itemId];

        address base = item.info.collateral.globalId();
        address quote = poolRegistry.currencyOfPool(poolId);

        return item.info.valuation.getQuote(1, base, quote).toUint128();
    }

    /// The valuation of this item
    function itemValue(PoolId poolId, ItemId itemId) external view returns (uint128 value) {
        uint128 price = this.getPrice(poolId, itemId);
        return items[poolId][itemId].outstandingQuantity.mulInt(price);
    }

    function nav(PoolId poolId) external view returns (uint128 value) {
        for (uint32 i = 0; i < itemNonces[poolId]; i++) {
            ItemId itemId = ItemId.wrap(i);
            if (items[poolId][itemId].exists()) {
                value += this.itemValue(poolId, itemId);
            }
        }
    }
}
