// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Portfolio.sol";
import "src/interfaces/IPortfolio.sol";
import "src/interfaces/INftEscrow.sol";

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
    IPoolRegistry poolRegistry = IPoolRegistry(address(0));
    IERC6909 nfts = IERC6909(address(0));
    IERC7726 valuation = IERC7726(address(0));
    INftEscrow escrow = INftEscrow(address(0));

    MockLinearAccrual linearAccrual = new MockLinearAccrual();

    address constant OWNER = address(1);
    uint64 constant POOL_A = 42;
    bytes32 constant INTEREST_RATE_A = bytes32(uint256(1));
    uint256 constant TOKEN_ID = 23;
    uint160 constant COLLATERAL_ID = 18;

    Portfolio portfolio = new Portfolio(address(this), poolRegistry, linearAccrual, escrow);

    function _mockAttach(uint32 itemId) internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.attach.selector, address(nfts), TOKEN_ID, itemId),
            abi.encode(18)
        );
    }

    function testCreate() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, nfts, TOKEN_ID);
        emit IPortfolio.Create(POOL_A, 2, nfts, TOKEN_ID); // Increasing Item ID for the second creation

        _mockAttach(1);
        portfolio.create(POOL_A, IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation), nfts, TOKEN_ID);

        _mockAttach(2);
        portfolio.create(POOL_A, IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation), nfts, TOKEN_ID);
    }

    /*
    function testIncrease() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation), nfts, TOKEN_ID);

        vm.expectEmit();
        emit IPortfolio.DebtIncreased(POOL_A, 1, 100);

        portfolio.increaseDebt(POOL_A, 1, 100);
    }

    function testDecrease() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation), nfts, TOKEN_ID);
        portfolio.increaseDebt(POOL_A, 1, 100);

        vm.expectEmit();
        emit IPortfolio.DebtDecreased(POOL_A, 1, 100, 0);

        portfolio.decreaseDebt(POOL_A, 1, 100, 0);
    }

    function testClose() public {
        portfolio.create(POOL_A, IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation), nfts, TOKEN_ID);

        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, 1);

        portfolio.close(POOL_A, 1);

        (,,,, bool isValid) = portfolio.items(POOL_A, 0);
        assert(isValid);
    }
    */
}
