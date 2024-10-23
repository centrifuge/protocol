// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "src/Portfolio.sol";
import "src/interfaces/IPortfolio.sol";
import "src/interfaces/INftEscrow.sol";

contract MockLinearAccrual is ILinearAccrual {
    function modifyNormalizedDebt(bytes32, int128 normalizedDebt, int128 increment) external pure returns (int128) {
        return normalizedDebt + increment;
    }

    function renormalizeDebt(bytes32, bytes32, int128 normalizedDebt) external pure returns (int128) {
        return normalizedDebt;
    }

    function debt(bytes32, int128 normalizedDebt) external pure returns (int128) {
        return normalizedDebt;
    }
}

contract TestCommon is Test {
    IPoolRegistry poolRegistry = IPoolRegistry(address(100));
    IERC6909 nfts = IERC6909(address(100));
    IERC7726 valuation = IERC7726(address(100));
    INftEscrow escrow = INftEscrow(address(100));

    MockLinearAccrual linearAccrual = new MockLinearAccrual();

    address constant OWNER = address(1);
    uint64 constant POOL_A = 42;
    bytes32 constant INTEREST_RATE_A = bytes32(uint256(1));
    uint256 constant TOKEN_ID = 23;
    uint160 constant COLLATERAL_ID = 18;
    IERC6909 constant NO_SOURCE = IERC6909(address(0));

    IPortfolio.ItemInfo ITEM_INFO = IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation);

    Portfolio portfolio = new Portfolio(address(this), poolRegistry, linearAccrual, escrow);

    function _mockAttach(uint256 itemId) internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.attach.selector, address(nfts), TOKEN_ID, uint256(POOL_A) << 64 + itemId),
            abi.encode(18)
        );
    }

    function getItem(uint32 itemId) internal view returns (Item memory) {
        (
            IPortfolio.ItemInfo memory info,
            int128 normalizedDebt,
            Decimal18 outstandingQuantity,
            uint160 collateralId,
            bool isValid
        ) = portfolio.items(POOL_A, itemId - 1);
        return Item(info, normalizedDebt, outstandingQuantity, collateralId, isValid);
    }
}

contract TestCreate is TestCommon {
    function testMultipleCreate() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, NO_SOURCE, 0);
        emit IPortfolio.Create(POOL_A, 2, NO_SOURCE, 0);

        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);
        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);
    }

    function testCreateNoCollateral() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, NO_SOURCE, 0);

        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);

        assert(getItem(1).isValid);
    }

    function testCreateWithCollateral() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, nfts, TOKEN_ID);

        _mockAttach(1);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        assert(getItem(1).isValid);
    }
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
