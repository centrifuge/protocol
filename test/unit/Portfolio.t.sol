// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Portfolio.sol";

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
}

contract TestPortfolio is Test {
    MockPoolRegistry poolRegistry = new MockPoolRegistry();
    MockLinearAccrual linearAccrual = new MockLinearAccrual();

    Portfolio portfolio;

    function setUp() public {
        portfolio = new Portfolio(address(1), poolRegistry, linearAccrual);
    }

    function testCreate() public {}
}
