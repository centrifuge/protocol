// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Decimal18, d18} from "src/libraries/Decimal18.sol";
import {MathLib} from "src/libraries/MathLib.sol";

interface IERC6909 {
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool success);
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        returns (bool success);
}

interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
    function getIndicativeQuote(uint256 baseAmount, address base, address quote)
        external
        view
        returns (uint256 quoteAmount);
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

    function renormalizeDebt(bytes32 rateId, bytes32 newRateId, uint128 prevNormalizedDebt)
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
    /// Issuer of this item
    address creator;
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

enum PricingMode {
    Real,
    Indicative
}

contract Portfolio {
    using MathLib for uint256;

    error ItemNotFound();
    error ItemCanNotBeClosed();
    error CollateralCanNotBeTransfered();

    event Create(PoolId, ItemId);
    event ValuationUpdated(PoolId, ItemId, IERC7726);
    event RateUpdated(PoolId, ItemId, bytes32 rateId);
    event DebtIncreased(PoolId, ItemId, uint128 amount);
    event DebtDecreased(PoolId, ItemId, uint128 amount, uint128 interest);
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

    /// Creates a new item based of a collateral.
    /// The owner of the collateral will be this contract until close is called.
    function create(PoolId poolId, ItemInfo calldata info) external {
        bool ok = info.collateral.source.transferFrom(info.creator, address(this), info.collateral.id, 1);
        require(ok, CollateralCanNotBeTransfered());

        ItemId itemId = ItemId.wrap(itemNonces[poolId]++);
        items[poolId][itemId] = Item(info, 0, d18(0));

        emit Create(poolId, itemId);
    }

    /// Update the rateId used by this item
    function updateRate(PoolId poolId, ItemId itemId, bytes32 rateId) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        item.normalizedDebt = linearAccrual.renormalizeDebt(item.info.rateId, rateId, item.normalizedDebt);
        item.info.rateId = rateId;

        emit RateUpdated(poolId, itemId, rateId);
    }

    /// Update the valuation contract address used for this item
    function updateValuation(PoolId poolId, ItemId itemId, IERC7726 valuation) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        item.info.valuation = valuation;

        emit ValuationUpdated(poolId, itemId, valuation);
    }

    /// Increase the debt of an item
    function increaseDebt(PoolId poolId, ItemId itemId, uint128 amount) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        Decimal18 quantity = _getQuantity(poolId, item, amount);

        item.normalizedDebt = linearAccrual.increaseNormalizedDebt(item.info.rateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity + quantity;

        emit DebtIncreased(poolId, itemId, amount);
    }

    /// Decrease the debt of an item
    function decreaseDebt(PoolId poolId, ItemId itemId, uint128 principal, uint128 interest) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        Decimal18 quantity = _getQuantity(poolId, item, principal);
        uint128 amount = principal + interest;

        item.normalizedDebt = linearAccrual.decreaseNormalizedDebt(item.info.rateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity - quantity;

        emit DebtDecreased(poolId, itemId, principal, interest);
    }

    /// Transfer debt `from` an item `to` another item.
    function transferDebt(PoolId poolId, ItemId from, ItemId to, uint128 principal, uint128 interest) external {
        this.decreaseDebt(poolId, from, principal, interest);
        this.increaseDebt(poolId, to, principal + interest);
    }

    /// Close a non-outstanding item returning the collateral to the creator of the item
    function close(PoolId poolId, ItemId itemId) external {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());
        require(item.outstandingQuantity.inner() == 0, ItemCanNotBeClosed());

        bool ok = item.info.collateral.source.transfer(item.info.creator, item.info.collateral.id, 1);
        require(ok, CollateralCanNotBeTransfered());

        delete items[poolId][itemId];

        emit Closed(poolId, itemId);
    }

    /// The item quantity for a pool currency amount
    function _getQuantity(PoolId poolId, Item storage item, uint128 amount) private view returns (Decimal18 quantity) {
        address base = poolRegistry.currencyOfPool(poolId);
        address quote = item.info.collateral.globalId();

        return d18(item.info.valuation.getQuote(amount, base, quote).toUint128());
    }

    /// The pool currency amount for some item quantity.
    function _getValue(PoolId poolId, Item storage item, Decimal18 quantity, PricingMode mode)
        private
        view
        returns (uint128 amount)
    {
        address base = item.info.collateral.globalId();
        address quote = poolRegistry.currencyOfPool(poolId);

        if (mode == PricingMode.Real) {
            return item.info.valuation.getQuote(quantity.inner(), base, quote).toUint128();
        } else {
            // mode == PricingMode.Indicative
            return item.info.valuation.getIndicativeQuote(quantity.inner(), base, quote).toUint128();
        }
    }

    /// Return the valuation of an item in the portfolio
    function itemValuation(PoolId poolId, ItemId itemId, PricingMode mode) external view returns (uint128 value) {
        Item storage item = items[poolId][itemId];
        require(item.exists(), ItemNotFound());

        return _getValue(poolId, item, item.outstandingQuantity, mode);
    }

    /// Return the Net Asset Value of all items in the portfolio
    function nav(PoolId poolId, PricingMode mode) external view returns (uint128 value) {
        for (uint32 i = 0; i < itemNonces[poolId]; i++) {
            ItemId itemId = ItemId.wrap(i);
            Item storage item = items[poolId][itemId];

            if (item.exists()) {
                value += _getValue(poolId, item, item.outstandingQuantity, mode);
            }
        }
    }
}
