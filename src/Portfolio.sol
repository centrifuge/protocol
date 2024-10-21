// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Decimal18, d18} from "src/libraries/Decimal18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Auth} from "src/Auth.sol";
import {IPortfolio, IValuation} from "src/interfaces/IPortfolio.sol";
import {IERC7726, IERC6909, IPoolRegistry, ILinearAccrual} from "src/interfaces/Common.sol";

struct Item {
    /// Base info of this item
    IPortfolio.ItemInfo info;
    /// A representation of the debt used by LinealAccrual to obtain the real debt
    uint128 normalizedDebt;
    /// Outstanding quantity
    Decimal18 outstandingQuantity;
    /// Existence flag
    bool isValid;
}

/// Absolute item itendification
struct ItemLocation {
    /// Identifiction of a pool
    uint64 poolId;
    /// Identifiction of an item inside of the pool
    uint32 itemId;
}

contract Portfolio is Auth, IPortfolio {
    using MathLib for uint256;

    IPoolRegistry public poolRegistry;
    ILinearAccrual public linearAccrual;

    /// A list of items (a portfolio) per pool.
    mapping(uint64 poolId => Item[]) public items;

    /// A list of collateral with an item associated.
    mapping(uint160 collateralId => ItemLocation) public usedCollaterals;

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

    function lock(IERC6909 source, uint256 tokenId, address from) external auth returns (uint160) {
        uint160 collateralId = _globalId(source, tokenId);

        // The token was already locked.
        require(source.balanceOf(address(this), tokenId) == 0, CollateralCanNotBeTransfered());

        bool ok = source.transferFrom(from, address(this), tokenId, 10 ** source.decimals(tokenId));
        require(ok, CollateralCanNotBeTransfered());

        emit Locked(source, tokenId, collateralId);

        return collateralId;
    }

    function unlock(IERC6909 source, uint256 tokenId, address to) external auth {
        bool ok = source.transferFrom(address(this), to, tokenId, 10 ** source.decimals(tokenId));

        emit Unlocked(source, tokenId);

        require(ok, CollateralCanNotBeTransfered());
    }

    /// @inheritdoc IPortfolio
    function create(uint64 poolId, ItemInfo calldata info) external auth {
        uint32 itemId = items[poolId].length.toUint32() + 1;

        if (info.collateralId != 0) {
            // TODO: Should we check if the collateral is locked?
            require(usedCollaterals[info.collateralId].itemId == 0, CollateralCanNotBeTransfered());
            usedCollaterals[info.collateralId] = ItemLocation(poolId, itemId);
        }

        items[poolId].push(Item(info, 0, d18(0), true));

        emit Create(poolId, itemId, info.collateralId);
    }

    /// @inheritdoc IPortfolio
    function updateInterestRate(uint64 poolId, uint32 itemId, bytes32 rateId) external auth {
        Item storage item = _getItem(poolId, itemId);

        item.normalizedDebt = linearAccrual.renormalizeDebt(item.info.interestRateId, rateId, item.normalizedDebt);
        item.info.interestRateId = rateId;

        emit InterestRateUpdated(poolId, itemId, rateId);
    }

    /// @inheritdoc IPortfolio
    function updateValuation(uint64 poolId, uint32 itemId, IERC7726 valuation) external auth {
        Item storage item = _getItem(poolId, itemId);

        item.info.valuation = valuation;

        emit ValuationUpdated(poolId, itemId, valuation);
    }

    /// @inheritdoc IPortfolio
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) public auth {
        Item storage item = _getItem(poolId, itemId);

        Decimal18 quantity = _getQuantity(poolId, item, amount);

        item.normalizedDebt =
            linearAccrual.increaseNormalizedDebt(item.info.interestRateId, item.normalizedDebt, amount);
        item.outstandingQuantity = item.outstandingQuantity + quantity;

        emit DebtIncreased(poolId, itemId, amount);
    }

    /// @inheritdoc IPortfolio
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 principal, uint128 interest) public auth {
        Item storage item = _getItem(poolId, itemId);

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
    function close(uint64 poolId, uint32 itemId) external auth {
        Item storage item = _getItem(poolId, itemId);
        require(item.outstandingQuantity.inner() == 0, ItemCanNotBeClosed()); // TODO: Can be removed?
        require(linearAccrual.debt(item.info.interestRateId, item.normalizedDebt) == 0, ItemCanNotBeClosed());

        if (item.info.collateralId != 0) {
            delete usedCollaterals[item.info.collateralId];
        }

        delete items[poolId][itemId];

        emit Closed(poolId, itemId);
    }

    /// @notice returns the debt of an item
    function debt(uint64 poolId, uint32 itemId) external view returns (uint128 debtValue) {
        Item storage item = _getItem(poolId, itemId);
        return linearAccrual.debt(item.info.interestRateId, item.normalizedDebt);
    }

    /// @inheritdoc IValuation
    function itemValuation(uint64 poolId, uint32 itemId, PricingMode mode) external view returns (uint128 value) {
        Item storage item = _getItem(poolId, itemId);

        return _getValue(poolId, item, item.outstandingQuantity, mode);
    }

    /// @inheritdoc IValuation
    function nav(uint64 poolId, PricingMode mode) external view returns (uint128 value) {
        for (uint32 itemPos = 0; itemPos < items[poolId].length; itemPos++) {
            Item storage item = items[poolId][itemPos];

            if (item.isValid) {
                value += _getValue(poolId, item, item.outstandingQuantity, mode);
            }
        }
    }

    function _getItem(uint64 poolId, uint32 itemId) internal view returns (Item storage) {
        Item storage item = items[poolId][itemId - 1];
        require(item.isValid, ItemNotFound());

        return item;
    }

    /// @dev Returns the identification of the collateral
    function _globalId(IERC6909 source, uint256 tokenId) internal pure returns (uint160) {
        return uint160(uint256(keccak256(abi.encode(source, tokenId))));
    }

    /// @dev The item quantity for a pool currency amount
    function _getQuantity(uint64 poolId, Item storage item, uint128 amount)
        internal
        view
        returns (Decimal18 quantity)
    {
        address base = poolRegistry.currencyOfPool(poolId);
        address quote = address(item.info.collateralId);

        return d18(item.info.valuation.getQuote(amount, base, quote).toUint128());
    }

    /// @dev The pool currency amount for some item quantity.
    function _getValue(uint64 poolId, Item storage item, Decimal18 quantity, PricingMode mode)
        internal
        view
        returns (uint128 amount)
    {
        address base = address(item.info.collateralId);
        address quote = poolRegistry.currencyOfPool(poolId);

        if (mode == PricingMode.Real) {
            return item.info.valuation.getQuote(quantity.inner(), base, quote).toUint128();
        } else {
            // mode == PricingMode.Indicative
            return item.info.valuation.getIndicativeQuote(quantity.inner(), base, quote).toUint128();
        }
    }
}
