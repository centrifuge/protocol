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

interface IAccessControl {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IPoolRegistry {
    function currencyOfPool(PoolId poolId) external view returns (address currency);
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

function collateralGlobalId(Collateral memory collateral) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encode(collateral.source, collateral.id)))));
}

/// Struct used for user inputs and "static" item data
struct ItemInfo {
    /// The account to able to act over this item
    address owner;
    /// The RWA used for this item as a collateral
    Collateral collateral;
    /// Fixed point rate
    Decimal18 interestRate;
    /// Fixed point number with the amount of asset hold by this item.
    /// Usually for Price valued items it will be > 1. Other valuations will normally set this value from 0-1.
    Decimal18 quantity;
    /// Valuation method
    IERC7726 valuationMethod;
    /// Unix timestamp measured in secs
    uint64 maturity;
}

struct Item {
    /// Base info of this item
    ItemInfo info;
    /// Total amount decreased by `decreaseDebt`. Measured in pool currency denomination
    uint128 totalDecreasedDebt;
    /// Total amount increased by `increaseDebt`. Measured in pool currency denomination
    uint128 totalIncreasedDebt;
    /// Total interest paid. Measured in pool currency denomination.
    uint128 totalInterestPaid;
    /// Outstanding quantity
    Decimal18 outstandingQuantity;
}

contract Portfolio {
    using MathLib for uint256;

    // TODO: add custom errors

    // TODO: extend with more properties
    event Create(PoolId, ItemId);
    event DebtIncreased(PoolId, ItemId);
    event DebtDecreased(PoolId, ItemId);
    event TransferDebt(PoolId, ItemId from, ItemId to);
    event Closed(PoolId, ItemId);

    mapping(PoolId => uint32 nonce) public itemNonces;
    mapping(PoolId => mapping(ItemId => Item)) public items;

    IAccessControl poolAdmin;
    IPoolRegistry poolRegistry;

    constructor(IAccessControl _poolAdmin, IPoolRegistry _poolRegistry) {
        poolAdmin = _poolAdmin;
        poolRegistry = _poolRegistry;
    }

    function create(PoolId poolId, ItemInfo calldata info) external {
        bytes32 poolAdminRole = bytes32(uint256(PoolId.unwrap(poolId)));
        require(poolAdmin.hasRole(poolAdminRole, msg.sender), "The creator should be the pool admin");

        bool ok = info.collateral.source.transfer(address(this), info.collateral.id, 1);
        require(ok, "Collateral can not be transfered to the contract");

        ItemId itemId = ItemId.wrap(itemNonces[poolId]++);
        items[poolId][itemId] = Item(info, 0, 0, 0, d18(0));

        emit Create(poolId, itemId);
    }

    function increaseDebt(PoolId poolId, ItemId itemId, Decimal18 quantity) external {
        Item storage item = items[poolId][itemId];
        require(item.info.owner == msg.sender, "Only the owner of the item can modify it");

        uint128 price = this.getPrice(poolId, itemId);

        item.outstandingQuantity = item.outstandingQuantity + quantity;
        item.totalIncreasedDebt += quantity.mulInt(price);

        emit DebtIncreased(poolId, itemId);
    }

    function decreaseDebt(PoolId poolId, ItemId itemId, Decimal18 principal, uint128 interest) external {
        //TODO: opposite to increaseDebt
    }

    function transferDebt(PoolId poolId, ItemId from, ItemId to, Decimal18 principal, uint128 interestPaid) external {
        //TODO: decreaseDebt(from) + increaseDebt(to)
    }

    function close(PoolId poolId, ItemId itemId) external {
        require(items[poolId][itemId].outstandingQuantity.inner() == 0, "The item must not have outstanding quantity");

        delete items[poolId][itemId];

        emit Closed(poolId, itemId);
    }

    /// The price for one element of this item.
    function getPrice(PoolId poolId, ItemId itemId) external view returns (uint128 value) {
        Item storage item = items[poolId][itemId];

        if (address(item.info.valuationMethod) != address(0)) {
            address base = collateralGlobalId(item.info.collateral);
            address quote = poolRegistry.currencyOfPool(poolId);

            return item.info.valuationMethod.getQuote(1, base, quote).toUint128();
        } else {
            //THINK: should I compute the debt per quantity unit or per item?
            // Right now, as it is, is per quantity. Does it makes sense?
            return computeDebt(poolId, itemId);
        }
    }

    /// The valuation of this item
    function valuation(PoolId poolId, ItemId itemId) external view returns (uint128 value) {
        uint128 price = this.getPrice(poolId, itemId);
        return items[poolId][itemId].outstandingQuantity.mulInt(price);
    }

    function computeDebt(PoolId poolId, ItemId itemId) public view returns (uint128 value) {
        //TODO
    }
}
