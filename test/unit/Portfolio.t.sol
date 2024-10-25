// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import "src/Portfolio.sol";
import "src/interfaces/IPortfolio.sol";
import "src/interfaces/INftEscrow.sol";

contract TestCommon is Test {
    // Mocks
    IPoolRegistry poolRegistry = IPoolRegistry(address(100));
    IERC6909 nfts = IERC6909(address(100));
    IERC7726 valuation = IERC7726(address(100));
    INftEscrow escrow = INftEscrow(address(100));
    ILinearAccrual linearAccrual = ILinearAccrual(address(100));

    address constant OWNER = address(1);
    uint64 constant POOL_A = 42;
    uint32 constant FIRST_ITEM_ID = 1;
    bytes32 constant INTEREST_RATE_A = bytes32(uint256(1));
    uint256 constant TOKEN_ID = 23;
    uint160 constant COLLATERAL_ID = 18;
    address constant POOL_CURRENCY = address(10);

    IPortfolio.ItemInfo ITEM_INFO = IPortfolio.ItemInfo(INTEREST_RATE_A, d18(10), valuation);

    Portfolio portfolio = new Portfolio(address(this), poolRegistry, linearAccrual, escrow);

    function setUp() public {
        _mockCurrency();
    }

    function _mockAttach(uint256 itemId) internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.attach.selector, address(nfts), TOKEN_ID, uint256(POOL_A) << 64 + itemId),
            abi.encode(COLLATERAL_ID)
        );
    }

    function _mockDetach() internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.detach.selector, address(nfts), COLLATERAL_ID),
            abi.encode()
        );
    }

    function _mockQuoteForQuantities(uint128 amount, Decimal18 quantity) internal {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(IERC7726.getQuote.selector, amount, POOL_CURRENCY, COLLATERAL_ID),
            abi.encode(quantity)
        );
    }

    function _mockCurrency() internal {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(IPoolRegistry.currency.selector, POOL_A),
            abi.encode(POOL_CURRENCY)
        );
    }

    function _mockModifyNormalizedDebt(int128 variation) internal {
        vm.mockCall(
            address(linearAccrual),
            abi.encodeWithSelector(ILinearAccrual.modifyNormalizedDebt.selector, INTEREST_RATE_A, 0, variation),
            abi.encode(0)
        );
    }

    function _mockDebt(int128 expectedDebt) internal {
        vm.mockCall(
            address(linearAccrual),
            abi.encodeWithSelector(ILinearAccrual.debt.selector, INTEREST_RATE_A, 0),
            abi.encode(expectedDebt)
        );
    }

    function _getItem(uint32 itemId) internal view returns (Item memory) {
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
    function testSuccess() public {
        _mockAttach(FIRST_ITEM_ID);
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, FIRST_ITEM_ID, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        assert(_getItem(FIRST_ITEM_ID).isValid);
        assertEq(_getItem(FIRST_ITEM_ID).collateralId, COLLATERAL_ID);
    }

    function testItemIdIncrement() public {
        _mockAttach(1);
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        _mockAttach(2);
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 2, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);
    }
}

contract TestClose is TestCommon {
    function testSuccess() public {
        _mockAttach(FIRST_ITEM_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        _mockDetach();
        _mockDebt(0);
        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, FIRST_ITEM_ID);
        portfolio.close(POOL_A, FIRST_ITEM_ID);

        assert(!_getItem(FIRST_ITEM_ID).isValid);
    }

    function testErrItemCanNotBeClosedDueQuantity() public {
        _mockAttach(FIRST_ITEM_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        _mockQuoteForQuantities(20, d18(5));
        _mockModifyNormalizedDebt(20);
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, 20);

        vm.expectRevert(abi.encodeWithSelector(IPortfolio.ItemCanNotBeClosed.selector));
        portfolio.close(POOL_A, FIRST_ITEM_ID);
    }

    function testErrItemCanNotBeClosedDueDebt() public {
        _mockAttach(FIRST_ITEM_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        _mockDebt(1);
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.ItemCanNotBeClosed.selector));
        portfolio.close(POOL_A, FIRST_ITEM_ID);
    }
}
