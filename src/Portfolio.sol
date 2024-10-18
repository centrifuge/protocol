// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Decimal18, d18} from "src/libraries/Decimal18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Auth} from "src/Auth.sol";
import {IPortfolio, IValuation} from "src/interfaces/IPortfolio.sol";
import {IERC7726, IERC6909, IPoolRegistry, ILinearAccrual} from "src/interfaces/Common.sol";

contract Portfolio is Auth, IPortfolio {
    using MathLib for uint256;

    struct Item {
        /// Base info of this item
        ItemInfo info;
        /// A representation of the debt used by LinealAccrual to obtain the real debt
        uint128 normalizedDebt;
        /// Outstanding quantity
        Decimal18 outstandingQuantity;
    }

    /// A list of items (a portfolio) per pool.
    mapping(uint64 poolId => Item[]) public items;

    IPoolRegistry public poolRegistry;
    ILinearAccrual public linearAccrual;

    event File(bytes32, address);

    constructor(address owner, IPoolRegistry poolRegistry_, ILinearAccrual linearAccrual_) Auth(owner) {
        poolRegistry = poolRegistry_;
        linearAccrual = linearAccrual_;
    }

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'poolRegistry', 'linearAccrual'
    function file(bytes32 what, address data) external auth {
        if (what == "poolRegistry") poolRegistry = IPoolRegistry(data);
        else if (what == "linearAccrual") linearAccrual = ILinearAccrual(data);
        else revert("Portfolio/file-unrecognized-param");
        emit File(what, data);
    }

    /// @inheritdoc IPortfolio
    function create(uint64 poolId, ItemInfo calldata info, address collateralOwner) external auth {
        bool ok = info.collateral.source.transferFrom(collateralOwner, address(this), info.collateral.id, 1);
        require(ok, CollateralCanNotBeTransfered());

        uint32 itemId = items[poolId].length.toUint32();
        items[poolId].push(Item(info, 0, d18(0)));

        emit Create(poolId, itemId, info.collateral);
    }

    /// @inheritdoc IPortfolio
    function updateInterestRate(uint64 poolId, uint32 itemId, bytes32 rateId) external auth {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());

        item.normalizedDebt = linearAccrual.renormalizeDebt(item.info.interestRateId, rateId, item.normalizedDebt);
        item.info.interestRateId = rateId;

        emit InterestRateUpdated(poolId, itemId, rateId);
    }

    /// @inheritdoc IPortfolio
    function updateValuation(uint64 poolId, uint32 itemId, IERC7726 valuation) external auth {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());

        item.info.valuation = valuation;

        emit ValuationUpdated(poolId, itemId, valuation);
    }

    /// @inheritdoc IPortfolio
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) public auth {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());

        Decimal18 quantity = _getQuantity(poolId, item, amount);

        item.normalizedDebt =
            linearAccrual.increaseNormalizedDebt(item.info.interestRateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity + quantity;

        emit DebtIncreased(poolId, itemId, amount);
    }

    /// @inheritdoc IPortfolio
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 principal, uint128 interest) public auth {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());

        Decimal18 quantity = _getQuantity(poolId, item, principal);

        /*
        uint128 debt = linearAccrual.debt(item.info.interestRateId, item.normalizedDebt);

        if (principal - quantity) {
            OverDecreasedPrincipal();
        }

        if (principal + interest > debt) {
            OverDecreasedInterest();
        }
        */

        item.normalizedDebt =
            linearAccrual.decreaseNormalizedDebt(item.info.interestRateId, item.normalizedDebt, principal + interest);
        item.outstandingQuantity = item.outstandingQuantity - quantity;

        emit DebtDecreased(poolId, itemId, principal, interest);
    }

    /// @inheritdoc IPortfolio
    function transferDebt(uint64 poolId, uint32 fromItemId, uint32 toItemId, uint128 principal, uint128 interest)
        external
        auth
    {
        decreaseDebt(poolId, fromItemId, principal, interest);
        increaseDebt(poolId, toItemId, principal + interest);
    }

    /// @inheritdoc IPortfolio
    function close(uint64 poolId, uint32 itemId, address collateralOwner) external auth {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());
        require(item.outstandingQuantity.inner() == 0, ItemCanNotBeClosed()); // TODO: Can be removed?
        require(linearAccrual.debt(item.info.interestRateId, item.normalizedDebt) == 0, ItemCanNotBeClosed());

        Collateral memory collateral = item.info.collateral;

        delete items[poolId][itemId];

        bool ok = collateral.source.transfer(collateralOwner, collateral.id, 1);
        require(ok, CollateralCanNotBeTransfered());

        emit Closed(poolId, itemId, collateralOwner);
    }

    /// @dev Returns the identification of the collateral
    function _globalId(Collateral storage collateral) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(collateral.source, collateral.id)))));
    }

    /// @dev Definition of a non-null item
    function _doItemExists(Item storage item) internal view returns (bool) {
        return address(item.info.collateral.source) != address(0);
    }

    /// @dev The item quantity for a pool currency amount
    function _getQuantity(uint64 poolId, Item storage item, uint128 amount)
        internal
        view
        returns (Decimal18 quantity)
    {
        address base = poolRegistry.currencyOfPool(poolId);
        address quote = _globalId(item.info.collateral);

        return d18(item.info.valuation.getQuote(amount, base, quote).toUint128());
    }

    /// @dev The pool currency amount for some item quantity.
    function _getValue(uint64 poolId, Item storage item, Decimal18 quantity, PricingMode mode)
        internal
        view
        returns (uint128 amount)
    {
        address base = _globalId(item.info.collateral);
        address quote = poolRegistry.currencyOfPool(poolId);

        if (mode == PricingMode.Real) {
            return item.info.valuation.getQuote(quantity.inner(), base, quote).toUint128();
        } else {
            // mode == PricingMode.Indicative
            return item.info.valuation.getIndicativeQuote(quantity.inner(), base, quote).toUint128();
        }
    }

    /// @notice returns the debt of an item
    function debt(uint64 poolId, uint32 itemId) external view returns (uint128 debtValue) {
        Item storage item = items[poolId][itemId];
        return linearAccrual.debt(item.info.interestRateId, item.normalizedDebt);
    }

    /// @inheritdoc IValuation
    function itemValuation(uint64 poolId, uint32 itemId, PricingMode mode) external view returns (uint128 value) {
        Item storage item = items[poolId][itemId];
        require(_doItemExists(item), ItemNotFound());

        return _getValue(poolId, item, item.outstandingQuantity, mode);
    }

    /// @inheritdoc IValuation
    function nav(uint64 poolId, PricingMode mode) external view returns (uint128 value) {
        for (uint32 itemId = 0; itemId < items[poolId].length; itemId++) {
            Item storage item = items[poolId][itemId];

            if (_doItemExists(item)) {
                value += _getValue(poolId, item, item.outstandingQuantity, mode);
            }
        }
    }
}
