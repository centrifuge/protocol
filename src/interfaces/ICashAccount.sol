// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IPortfolio} from "src/interfaces/IPortfolio.sol";

// TODO: is IItem?
interface ICashAccount {
    // TODO: Does it make sense to replicate events such as Create from Portfolio? Then we would emit two events for a
    // new CashAccount Item

    error NotOwner(uint64 poolId, uint32 itemId);

    // TODO TBD: Initiates item with no collateral, zero interest rate, valuation as address(0) and zero quantity as
    /// quantity is increased when depositing.
    /// @notice Creates a new item and links it to the provided owner
    /// @param poolId The pool to which this item belongs
    /// @param owner The address of the owner of the item which is authorized to deposit and withdraw
    function create(uint64 poolId, address owner) external;

    /// @notice Denote a deposit of onchain pool reserve balance into offchain cash account
    ///
    /// @param poolId The identifier of the pool of the reserve which was tapped into
    /// @param itemId The identifier of the item for which the deposit occured
    /// @param principal The debt amount of pool reserve balance which was deposited
    function deposit(uint64 poolId, uint32 itemId, uint128 principal) external;

    /// @notice Denote a withdrawal of balance in offchain cash account back into onchain pool reserve
    ///
    /// @param poolId The identifier of the pool of the reserve which receives back balance
    /// @param itemId The identifier of the item for which the withdrawal occured
    /// @param principal The debt amount of pool reserve balance which was repaid
    /// @param unscheduled The unexpected repayment amount of balance which is not part of the debt
    function withdraw(uint64 poolId, uint32 itemId, uint128 principal, uint128 unscheduled) external;

    /// @notice Increase the debt for an item of a pool
    ///
    /// @param poolId The identifier of the pool
    /// @param itemId The identifier of the item for which we increase the debt
    /// @param amount The balance amount by which we increase the debt of the item
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) external;

    /// @notice Decrease the debt for an item of a pool
    ///
    /// @param poolId The identifier of the pool
    /// @param itemId The identifier of the item for which we decrease the debt
    /// @param amount The balance amount by which we decrease the debt of the item
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 amount) external;

    /// @notice Close a non-outstanding item returning the collateral to the `collateralOwner`
    // TODO: If we agree on not requiring collaterals here, `collateralOwner` could be removed
    /// @param collateralOwner The address where to transfer back the collateral representing the portfolio item
    function close(uint64 poolId, uint32 itemId, address collateralOwner) external;
}
