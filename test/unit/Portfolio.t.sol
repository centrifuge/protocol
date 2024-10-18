// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Portfolio.sol";
import "src/interfaces/IPortfolio.sol";

contract MockERC6909 is IERC6909 {
    function transfer(address, uint256, uint256) external pure returns (bool success) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool success) {
        return true;
    }
}

contract MockERC7726 is IERC7726 {
    function getQuote(uint256 baseAmount, address, address) external pure returns (uint256 quoteAmount) {
        return baseAmount * 2;
    }

    function getIndicativeQuote(uint256 baseAmount, address, address) external pure returns (uint256 quoteAmount) {
        return baseAmount / 2;
    }
}

contract MockPoolRegistry is IPoolRegistry {
    function currencyOfPool(uint64) external pure returns (address currency) {
        return address(42);
    }
}

contract MockLinearAccrual is ILinearAccrual {
    function increaseNormalizedDebt(bytes32, uint128 prevNormalizedDebt, uint128 increment)
        external
        pure
        returns (uint128 newNormalizedDebt)
    {
        return prevNormalizedDebt + increment;
    }

    function decreaseNormalizedDebt(bytes32, uint128 prevNormalizedDebt, uint128 decrement)
        external
        pure
        returns (uint128 newNormalizedDebt)
    {
        return prevNormalizedDebt + decrement;
    }

    function renormalizeDebt(bytes32, bytes32, uint128 prevNormalizedDebt)
        external
        pure
        returns (uint128 newNormalizedDebt)
    {
        return prevNormalizedDebt;
    }

    function debt(bytes32, uint128 normalizedDebt) external pure returns (uint128) {
        return normalizedDebt;
    }
}

contract TestPortfolio is Test {
    MockPoolRegistry poolRegistry = new MockPoolRegistry();
    MockLinearAccrual linearAccrual = new MockLinearAccrual();

    address constant OWNER = address(1);
    uint64 constant POOL_A = 42;
    bytes32 constant INTEREST_RATE_A = bytes32(uint256(1));

    MockERC6909 collection = new MockERC6909();
    MockERC7726 valuation = new MockERC7726();
    IPortfolio.Collateral collateral = IPortfolio.Collateral(collection, 1);

    Portfolio portfolio = new Portfolio(address(this), poolRegistry, linearAccrual);

    function testCreate() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 0, collateral);
        emit IPortfolio.Create(POOL_A, 1, collateral); // Increasing Item ID for the second creation

        portfolio.create(POOL_A, IPortfolio.ItemInfo(collateral, INTEREST_RATE_A, d18(10), valuation), OWNER);
        portfolio.create(POOL_A, IPortfolio.ItemInfo(collateral, INTEREST_RATE_A, d18(10), valuation), OWNER);
    }

    function testIncrease() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(collateral, INTEREST_RATE_A, d18(10), valuation), OWNER);

        vm.expectEmit();
        emit IPortfolio.DebtIncreased(POOL_A, 0, 100);

        portfolio.increaseDebt(POOL_A, 0, 100);
    }

    function testDecrease() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(collateral, INTEREST_RATE_A, d18(10), valuation), OWNER);
        portfolio.increaseDebt(POOL_A, 0, 100);

        vm.expectEmit();
        emit IPortfolio.DebtDecreased(POOL_A, 0, 100, 0);

        portfolio.decreaseDebt(POOL_A, 0, 100, 0);
    }

    function testCloseAfterCreate() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(collateral, INTEREST_RATE_A, d18(10), valuation), OWNER);

        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, 0, OWNER);

        portfolio.close(POOL_A, 0, OWNER);

        (IPortfolio.ItemInfo memory info,,) = portfolio.items(POOL_A, 0);
        assertEq(address(info.collateral.source), address(0));
    }
}
