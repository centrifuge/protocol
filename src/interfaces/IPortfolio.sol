// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

import {IERC7726, IERC6909} from "src/interfaces/Common.sol";
import {Decimal18} from "src/libraries/Decimal18.sol";

/// @notice Defines a set of items that can be valued
interface IValuation {
    /// @notice How the price is used to value each item.
    enum PricingMode {
        /// @dev Underlaying call to `ERC6909.getQuote()`
        Real,
        /// @dev Underlaying call to `ERC6909.getIndicativeQuote()`
        Indicative
    }

    /// @notice Return the Net Asset Value of all items in the portfolio
    /// @param mode How the items are valued
    function nav(uint64 poolId, PricingMode mode) external view returns (uint128 value);
}

/// @notice Defines methods to interact with the items of a portfolio
interface IPortfolio is IValuation {
    /// @notice Struct used for user inputs and "static" item data
    struct ItemInfo {
        /// @notice Rate identification to compute the interest.
        bytes32 interestRateId;
        /// @notice Fixed point number with the amount of asset hold by this item.
        /// Usually for Price valued items it will be > 1.
        /// Other valuations will normally set this value from 0-1.
        Decimal18 quantity;
        /// @notice Valuation used for this item.
        IERC7726 valuation;
    }

    /// @notice Dispatched when the item can not be found.
    error ItemNotFound();

    /// @notice Dispatched when the item can not be closed yet.
    error ItemCanNotBeClosed();

    /// @notice Dispatched after the creation of an item.
    event Create(uint64 indexed poolId, uint32 itemId, IERC6909 source, uint256 tokenId);

    /// @notice Dispatched when the item lifetime ends
    event Closed(uint64 indexed poolId, uint32 itemId);

    /// @notice Dispatched when the item valuation has been updated.
    event ValuationUpdated(uint64 indexed poolId, uint32 itemId, IERC7726);

    /// @notice Dispatched when the interest rate has been updated.
    event InterestRateUpdated(uint64 indexed poolId, uint32 itemId, bytes32 rateId);

    /// @notice Dispatched when the item debt has been increased.
    event DebtIncreased(uint64 indexed poolId, uint32 itemId, uint128 amount);

    /// @notice Dispatched when the item debt has been decreased.
    event DebtDecreased(uint64 indexed poolId, uint32 itemId, uint128 principal, uint128 interest);

    /// @notice Creates a new item.
    /// The collateral defined by `source` and `tokenId` is lock to this item until close is called.
    /// @param info Item related information
    /// @param source Contract where the collateral defined by `tokenId` exists.
    /// If zero, then no collateral is used for this item.
    /// @param tokenId Asset used for this item as collateral.
    /// If `source == 0` then this param does not take effect.
    function create(uint64 poolId, ItemInfo calldata info, IERC6909 source, uint256 tokenId) external;

    /// @notice Close a non-outstanding item
    /// If a collateral was attached to this item, now the collateral is free.
    function close(uint64 poolId, uint32 itemId) external;

    /// @notice Update the interest rate used by this item
    /// @param rateId Interest rate identification
    function updateInterestRate(uint64 poolId, uint32 itemId, bytes32 rateId) external;

    /// @notice Update the valuation contract address used for this item
    function updateValuation(uint64 poolId, uint32 itemId, IERC7726 valuation) external;

    /// @notice Increase the debt of an item.
    /// Depending on the configured interest rate, the debt will increase over the time based on the amount given.
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) external;

    /// @notice Decrease the debt of an item
    /// @param principal Amount used to decrease the base debt amount from where the interest is accrued.
    /// @param interest Amount used to decrease the pending interest accrued in this item.
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 principal, uint128 interest) external;

    /// @notice Transfer debt `from` an item `to` another item.
    /// @param fromItemId The item from which to decrease the debt.
    /// @param toItemId The item from which to increase the debt.
    /// @param principal Amount used to decrease the base debt amount from where the interest is accrued.
    /// @param interest Amount used to decrease the pending interest accrued in this item.
    function transferDebt(uint64 poolId, uint32 fromItemId, uint32 toItemId, uint128 principal, uint128 interest)
        external;

    /// @notice returns the debt of an item
    function debt(uint64 poolId, uint32 itemId) external view returns (int128 debt_);

    /// @notice Return the valuation of an item in the portfolio
    /// @param mode How the item is valued
    function itemValuation(uint64 poolId, uint32 itemId, PricingMode mode) external view returns (uint128 value);
}
