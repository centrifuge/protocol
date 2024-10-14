// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {IERC7726, IERC6909} from "src/interfaces/Common.sol";
import {Decimal18} from "src/libraries/Decimal18.sol";

interface IValuation {
    error ItemNotFound();

    enum PricingMode {
        Real,
        Indicative
    }

    /// Return the valuation of an item in the portfolio
    function itemValuation(uint64 poolId, uint32 itemId, PricingMode mode) external view returns (uint128 value);

    /// Return the Net Asset Value of all items in the portfolio
    function nav(uint64 poolId, PricingMode mode) external view returns (uint128 value);
}

interface IPortfolio is IValuation {
    /// Required data to locate the collateral
    struct Collateral {
        /// Contract where the collateral exists
        IERC6909 source;
        /// Identification of the collateral in that contract
        uint256 id;
    }

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

    error ItemCanNotBeClosed();
    error CollateralCanNotBeTransfered();

    event Create(uint64 indexed poolId, uint32 itemId);
    event ValuationUpdated(uint64 indexed poolId, uint32 itemId, IERC7726);
    event RateUpdated(uint64 indexed poolId, uint32 itemId, bytes32 rateId);
    event DebtIncreased(uint64 indexed poolId, uint32 itemId, uint128 amount);
    event DebtDecreased(uint64 indexed poolId, uint32 itemId, uint128 amount, uint128 interest);
    event TransferDebt(uint64 indexed poolId, uint32 fromItemId, uint32 toItemId, Decimal18 quantity, uint128 interest);
    event Closed(uint64 indexed poolId, uint32 itemId);

    /// Creates a new item based of a collateral.
    /// The owner of the collateral will be this contract until close is called.
    function create(uint64 poolId, ItemInfo calldata info, address creator) external;

    /// Update the rateId used by this item
    function updateRate(uint64 poolId, uint32 itemId, bytes32 rateId) external;

    /// Update the valuation contract address used for this item
    function updateValuation(uint64 poolId, uint32 itemId, IERC7726 valuation) external;

    /// Increase the debt of an item
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) external;

    /// Decrease the debt of an item
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 principal, uint128 interest) external;

    /// Transfer debt `from` an item `to` another item.
    function transferDebt(uint64 poolId, uint32 fromItemId, uint32 toItemId, uint128 principal, uint128 interest)
        external;

    /// Close a non-outstanding item returning the collateral to the creator of the item
    function close(uint64 poolId, uint32 itemId, address creator) external;
}
