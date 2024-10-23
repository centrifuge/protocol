// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Decimal18, d18} from "src/libraries/Decimal18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Auth} from "src/Auth.sol";
import {INftEscrow} from "src/interfaces/INftEscrow.sol";
import {IPortfolio, IValuation} from "src/interfaces/IPortfolio.sol";
import {IERC7726, IERC6909, IPoolRegistry, ILinearAccrual} from "src/interfaces/Common.sol";

struct Item {
    /// Base info of this item
    IPortfolio.ItemInfo info;
    /// A representation of the debt used by LinealAccrual to obtain the real debt
    int128 normalizedDebt;
    /// Outstanding quantity
    Decimal18 outstandingQuantity;
    /// Identification of the asset used for this item
    uint160 collateralId;
    /// Existence flag
    bool isValid;
}

contract Portfolio is Auth, IPortfolio {
    using MathLib for uint256;
    using MathLib for uint128;

    IPoolRegistry public poolRegistry;
    ILinearAccrual public linearAccrual;
    INftEscrow public nftEscrow;

    /// A list of items (a portfolio) per pool.
    mapping(uint64 poolId => Item[]) public items;

    event File(bytes32, address);

    constructor(address owner, IPoolRegistry poolRegistry_, ILinearAccrual linearAccrual_, INftEscrow nftEscrow_)
        Auth(owner)
    {
        poolRegistry = poolRegistry_;
        linearAccrual = linearAccrual_;
        nftEscrow = nftEscrow_;
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
    function create(uint64 poolId, ItemInfo calldata info, IERC6909 source, uint256 tokenId) external auth {
        uint32 itemId = items[poolId].length.toUint32() + 1;

        uint160 collateralId = 0;
        if (address(source) != address(0)) {
            uint256 uniqueItemId = uint256(poolId) << 64 + itemId;
            collateralId = nftEscrow.attach(source, tokenId, uniqueItemId);
        }

        items[poolId].push(Item(info, 0, d18(0), collateralId, true));

        emit Create(poolId, itemId, source, tokenId);
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

        // TODO: Handle the case when currently the current debt is negative

        item.normalizedDebt =
            linearAccrual.modifyNormalizedDebt(item.info.interestRateId, item.normalizedDebt, amount.toInt128());
        item.outstandingQuantity = item.outstandingQuantity + quantity;

        emit DebtIncreased(poolId, itemId, amount);
    }

    /// @inheritdoc IPortfolio
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 principal, uint128 interest) public auth {
        Item storage item = _getItem(poolId, itemId);

        Decimal18 quantity = _getQuantity(poolId, item, principal);

        // TODO: Handle the case when principal + intereset > current debt.

        item.normalizedDebt = linearAccrual.modifyNormalizedDebt(
            item.info.interestRateId, item.normalizedDebt, -(principal + interest).toInt128()
        );
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
        require(item.outstandingQuantity.inner() == 0, ItemCanNotBeClosed());
        require(linearAccrual.debt(item.info.interestRateId, item.normalizedDebt) <= 0, ItemCanNotBeClosed());

        uint160 collateralId = item.collateralId;

        delete items[poolId][itemId];

        if (collateralId != 0) {
            nftEscrow.detach(collateralId);
        }

        emit Closed(poolId, itemId);
    }

    /// @inheritdoc IPortfolio
    function debt(uint64 poolId, uint32 itemId) external view returns (int128 debt_) {
        Item storage item = _getItem(poolId, itemId);
        return linearAccrual.debt(item.info.interestRateId, item.normalizedDebt);
    }

    /// @inheritdoc IPortfolio
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

    /// @dev returns an item given both poolId and itemId
    function _getItem(uint64 poolId, uint32 itemId) private view returns (Item storage) {
        Item storage item = items[poolId][itemId - 1];
        require(item.isValid, ItemNotFound());

        return item;
    }

    /// @dev The item quantity for a pool currency amount
    function _getQuantity(uint64 poolId, Item storage item, uint128 amount)
        internal
        view
        returns (Decimal18 quantity)
    {
        address base = poolRegistry.currencyOfPool(poolId);
        address quote = address(item.collateralId);

        return d18(item.info.valuation.getQuote(amount, base, quote).toUint128());
    }

    /// @dev The pool currency amount for some item quantity.
    function _getValue(uint64 poolId, Item storage item, Decimal18 quantity, PricingMode mode)
        internal
        view
        returns (uint128 amount)
    {
        address base = address(item.collateralId);
        address quote = poolRegistry.currencyOfPool(poolId);

        if (mode == PricingMode.Real) {
            return item.info.valuation.getQuote(quantity.inner(), base, quote).toUint128();
        } else {
            // mode == PricingMode.Indicative
            // TODO: Using the indicative value instead
            return item.info.valuation.getQuote(quantity.inner(), base, quote).toUint128();
        }
    }
}
