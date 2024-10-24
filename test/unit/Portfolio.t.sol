// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
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

    function _mockQuote(Decimal18 quantity, address quote) internal {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(IERC7726.getQuote.selector, quantity.inner(), POOL_CURRENCY, quote),
            abi.encode(quantity.inner())
        );
    }

    function _mockCurrency() internal {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(IPoolRegistry.currency.selector, POOL_A),
            abi.encode(POOL_CURRENCY)
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
    function testSuccessMultiple() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, NO_SOURCE, 0);
        emit IPortfolio.Create(POOL_A, 2, NO_SOURCE, 0);

        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);
        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);
    }

    function testSuccessWithoutCollateral() public {
        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, NO_SOURCE, 0);
        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);

        assert(_getItem(1).isValid);
        assertEq(_getItem(1).collateralId, 0);
    }

    function testSuccessWithCollateral() public {
        _mockAttach(1);

        vm.expectEmit();
        emit IPortfolio.Create(POOL_A, 1, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);

        assert(_getItem(1).isValid);
        assertEq(_getItem(1).collateralId, COLLATERAL_ID);
    }
}

contract TestClose is TestCommon {
    function testSuccessWithoutCollateral() public {
        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);

        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, 1);
        portfolio.close(POOL_A, 1);

        assert(!_getItem(1).isValid);
    }

    function testSuccessWithCollateral() public {
        _mockAttach(1);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID);
        _mockDetach();

        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, 1);
        portfolio.close(POOL_A, 1);

        assert(!_getItem(1).isValid);
    }

    function testErrItemCanNotBeClosed() public {
        portfolio.create(POOL_A, ITEM_INFO, NO_SOURCE, 0);

        _mockQuote(d18(5), address(0));
        portfolio.increaseDebt(POOL_A, 1, 5);

        vm.expectRevert(abi.encodeWithSelector(IPortfolio.ItemCanNotBeClosed.selector));
        portfolio.close(POOL_A, 1);
    }
}
