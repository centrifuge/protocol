// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {ItemId, AccountId} from "src/types/Domain.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";

interface IItemManager {
    /// @notice Creates a new item in a pool using a valuation
    function create(PoolId poolId, IERC7726 valuation, AccountId[] memory accounts, bytes calldata data) external;

    /// @notice Closes an item in a pool using a valuation
    /// An item can only be closed if their value is 0.
    function close(PoolId poolId, ItemId itemId, bytes calldata data) external;

    /// @notice Increments the amount of an item and updates the value for that increment.
    /// @return value The value the item has increment.
    function increase(PoolId poolId, ItemId itemId, uint128 amount, IERC7726 valuation)
        external
        returns (uint128 value);

    /// @notice Decrements the amount of an item and updates the value for that decrement.
    /// @return value The value the item has decrement.
    function decrease(PoolId poolId, ItemId itemId, uint128 amount, IERC7726 valuation)
        external
        returns (uint128 value);

    /// @notice Increments the interest of an item.
    /// @param interestAmount The amount of interest to be incremented.
    function increaseInterest(PoolId poolId, ItemId itemId, uint128 interestAmount) external;

    /// @notice Decrements the interest of an item.
    /// @param interestAmount The amount of interest to be decremented.
    function decreaseInterest(PoolId poolId, ItemId itemId, uint128 interestAmount) external;

    /// @notice Reset the value of an item using the current valuation.
    /// @return diff The difference in value after the new valuation.
    function update(PoolId poolId, ItemId itemId) external returns (int128 diff);

    /// @notice Returns the item value of this item.
    function itemValue(PoolId poolId, ItemId itemId) external view returns (uint128 value);

    /// @notice Returns the valuation method used for this item.
    function valuation(PoolId poolId, ItemId itemId) external view returns (IERC7726);

    /// @notice Updates the valuation method used for this item.
    function updateValuation(PoolId poolId, ItemId itemId, IERC7726 valuation) external;

    /// @notice Sets an account id for an specific kind
    function setAccountId(PoolId poolId, ItemId itemId, AccountId id) external;

    /// @notice Returns an account id for an specific kind
    function accountId(PoolId poolId, ItemId itemId, uint8 kind) external view returns (AccountId);
}
