// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IPortfolio} from "src/interfaces/IPortfolio.sol";
import {ICashAccount} from "src/interfaces/ICashAccount.sol";

// TODO: is IItem?
contract CashAccount is ICashAccount {
    // IShareManager public shareManager;
    IPortfolio public portfolio;

    // TODO: Should probably be replaced with querying from top level contract. However, Portfolio only stores array of
    // items.
    mapping(uint128 poolId => mapping(uint32 itemId => address owner)) owners;

    modifier onlyOwner(uint64 poolId, uint32 itemId, address owner_) {
        require(owner_ == owners[poolId][itemId], NotOwner(poolId, itemId));
        _;
    }
    /// @inheritdoc ICashAccount

    function create(uint64 poolId, address owner) external {
        // TODO(from spec): Call portfolio.lock
        // TODO(from spec): Call portfolio.create
        // TODO(from spec): Set valuation to address(0)

        // TODO: Get itemId from creation
        // TODO: owners[poolId][itemId] = owner;
    }

    /// @inheritdoc ICashAccount
    function deposit(uint64 poolId, uint32 itemId, uint128 principal) public onlyOwner(poolId, itemId, msg.sender) {
        // TODO(from spec): Withdraw from share manager: shareManager.withdraw(poolId, itemId, principal);
        // TODO(from spec): Increase debt: increaseDebt(poolId, itemId, principal);
    }

    /// @inheritdoc ICashAccount
    function withdraw(uint64 poolId, uint32 itemId, uint128 principal, uint128 unscheduled)
        public
        onlyOwner(poolId, itemId, msg.sender)
    {
        // TODO(from spec): Deposit into share manager: shareManager.deposit(poolId, itemId, principal, unscheduled);
        // TODO(from spec): Decrease debt: decreaseDebt(poolId, itemId, principal + unscheduled);
    }

    /// @inheritdoc ICashAccount
    function increaseDebt(uint64 poolId, uint32 itemId, uint128 amount) public onlyOwner(poolId, itemId, msg.sender) {
        // TODO(from spec): portfolio.increaseDebt(poolId, itemId, amount);
    }

    /// @inheritdoc ICashAccount
    function decreaseDebt(uint64 poolId, uint32 itemId, uint128 amount) public onlyOwner(poolId, itemId, msg.sender) {
        // TODO(from spec): portfolio.decreaseDebt(poolId, itemId, amount);
    }

    /// @inheritdoc ICashAccount
    function close(uint64 poolId, uint32 itemId, address collateralOwner) external {
        // TODO(@wischli): Impl
    }
}
