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
        _mockLock();
        _mockUnlock();
        _mockComputeNftId();
    }

    function _mockCurrency() internal {
        vm.mockCall(
            address(poolRegistry),
            abi.encodeWithSelector(IPoolRegistry.currency.selector, POOL_A),
            abi.encode(POOL_CURRENCY)
        );
    }

    function _mockLock() internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.lock.selector, address(nfts), TOKEN_ID, OWNER),
            abi.encode()
        );
    }

    function _mockUnlock() internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.unlock.selector, address(nfts), TOKEN_ID, OWNER),
            abi.encode()
        );
    }

    function _mockComputeNftId() internal {
        vm.mockCall(
            address(escrow),
            abi.encodeWithSelector(INftEscrow.computeNftId.selector, address(nfts), TOKEN_ID),
            abi.encode(COLLATERAL_ID)
        );
    }

    function _mockQuoteForQuantities(uint128 amount, D18 quantity) internal {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(IERC7726.getQuote.selector, amount, POOL_CURRENCY, COLLATERAL_ID),
            abi.encode(quantity)
        );
    }

    function _mockQuoteForAmount(D18 quantity, uint128 amount) internal {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(IERC7726.getQuote.selector, quantity, COLLATERAL_ID, POOL_CURRENCY),
            abi.encode(amount)
        );
    }

    function _mockModifyNormalizedDebt(int128 variation, int128 pre, int128 post) internal {
        vm.mockCall(
            address(linearAccrual),
            abi.encodeWithSelector(ILinearAccrual.modifyNormalizedDebt.selector, INTEREST_RATE_A, pre, variation),
            abi.encode(post)
        );
    }

    function _mockRenormalizeDebt(bytes32 interestRateId, int128 pre, int128 post) internal {
        vm.mockCall(
            address(linearAccrual),
            abi.encodeWithSelector(ILinearAccrual.renormalizeDebt.selector, INTEREST_RATE_A, interestRateId, pre),
            abi.encode(post)
        );
    }

    function _mockDebt(int128 pre, int128 post) internal {
        vm.mockCall(
            address(linearAccrual),
            abi.encodeWithSelector(ILinearAccrual.debt.selector, INTEREST_RATE_A, pre),
            abi.encode(post)
        );
    }

    function _getItem(uint32 itemId) internal view returns (Item memory) {
        (
            IPortfolio.ItemInfo memory info,
            int128 normalizedDebt,
            D18 outstandingQuantity,
            uint160 collateralId,
            bool isValid
        ) = portfolio.items(POOL_A, itemId - 1);
        return Item(info, normalizedDebt, outstandingQuantity, collateralId, isValid);
    }
}

contract TestFile is TestCommon {
    address constant NEW_ADDRESS = address(1234);

    function testPoolRegistry() public {
        vm.expectEmit();
        emit IPortfolio.File("poolRegistry", NEW_ADDRESS);
        portfolio.file("poolRegistry", NEW_ADDRESS);

        assertEq(address(portfolio.poolRegistry()), NEW_ADDRESS);
    }

    function testLinearAccrual() public {
        vm.expectEmit();
        emit IPortfolio.File("linearAccrual", NEW_ADDRESS);
        portfolio.file("linearAccrual", NEW_ADDRESS);

        assertEq(address(portfolio.linearAccrual()), NEW_ADDRESS);
    }

    function testNftEscrow() public {
        vm.expectEmit();
        emit IPortfolio.File("nftEscrow", NEW_ADDRESS);
        portfolio.file("nftEscrow", NEW_ADDRESS);

        assertEq(address(portfolio.nftEscrow()), NEW_ADDRESS);
    }
}

contract TestCreate is TestCommon {
    function testSuccess() public {
        vm.expectEmit();
        emit IPortfolio.Created(POOL_A, FIRST_ITEM_ID, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        assert(_getItem(FIRST_ITEM_ID).isValid);
        assertEq(_getItem(FIRST_ITEM_ID).collateralId, COLLATERAL_ID);
    }

    function testItemIdIncrement() public {
        vm.expectEmit();
        emit IPortfolio.Created(POOL_A, 1, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        vm.expectEmit();
        emit IPortfolio.Created(POOL_A, 2, nfts, TOKEN_ID);
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);
    }
}

contract TestClose is TestCommon {
    function testSuccess() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockDebt(0, 0);
        vm.expectEmit();
        emit IPortfolio.Closed(POOL_A, FIRST_ITEM_ID);
        portfolio.close(POOL_A, FIRST_ITEM_ID, nfts, TOKEN_ID, OWNER);

        assert(!_getItem(FIRST_ITEM_ID).isValid);
    }

    function testErrItemCanNotBeClosedDueQuantity() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(20, d18(5));
        _mockModifyNormalizedDebt(20, 0, 0);
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, 20);

        vm.expectRevert(abi.encodeWithSelector(IPortfolio.ItemCanNotBeClosed.selector));
        portfolio.close(POOL_A, FIRST_ITEM_ID, nfts, TOKEN_ID, OWNER);
    }

    function testErrItemCanNotBeClosedDueDebt() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockDebt(0, 1);
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.ItemCanNotBeClosed.selector));
        portfolio.close(POOL_A, FIRST_ITEM_ID, nfts, TOKEN_ID, OWNER);
    }
}

contract TestUpdateInterestRate is TestCommon {
    bytes32 constant INTEREST_RATE_B = bytes32(uint256(2));

    function testSuccess() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockRenormalizeDebt(INTEREST_RATE_B, 0, 1);
        vm.expectEmit();
        emit IPortfolio.InterestRateUpdated(POOL_A, FIRST_ITEM_ID, INTEREST_RATE_B);
        portfolio.updateInterestRate(POOL_A, FIRST_ITEM_ID, INTEREST_RATE_B);

        assertEq(_getItem(FIRST_ITEM_ID).normalizedDebt, 1);
        assertEq(_getItem(FIRST_ITEM_ID).info.interestRateId, INTEREST_RATE_B);
    }
}

contract TestUpdateValutation is TestCommon {
    IERC7726 newValuation = IERC7726(address(101));

    function testSuccess() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        vm.expectEmit();
        emit IPortfolio.ValuationUpdated(POOL_A, FIRST_ITEM_ID, newValuation);
        portfolio.updateValuation(POOL_A, FIRST_ITEM_ID, newValuation);

        assertEq(address(_getItem(FIRST_ITEM_ID).info.valuation), address(newValuation));
    }
}

contract TestIncreaseDebt is TestCommon {
    uint128 constant AMOUNT = 20;

    function testSuccess() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(AMOUNT, d18(2));
        _mockModifyNormalizedDebt(int128(AMOUNT), 0, int128(AMOUNT));
        vm.expectEmit();
        emit IPortfolio.DebtIncreased(POOL_A, FIRST_ITEM_ID, AMOUNT);
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, AMOUNT);

        assertEq(_getItem(FIRST_ITEM_ID).outstandingQuantity.inner(), d18(2).inner());
        assertEq(_getItem(FIRST_ITEM_ID).normalizedDebt, int128(AMOUNT));
    }

    function testIncreaseOverIncrease() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(AMOUNT, d18(2));
        _mockModifyNormalizedDebt(int128(AMOUNT), 0, int128(AMOUNT));
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, AMOUNT);

        _mockModifyNormalizedDebt(int128(AMOUNT), int128(AMOUNT), int128(AMOUNT * 2));
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, AMOUNT);

        assertEq(_getItem(FIRST_ITEM_ID).outstandingQuantity.inner(), d18(4).inner());
        assertEq(_getItem(FIRST_ITEM_ID).normalizedDebt, int128(AMOUNT * 2));
    }

    function testErrTooMuchDebt() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(AMOUNT, ITEM_INFO.quantity + d18(1));
        _mockModifyNormalizedDebt(int128(AMOUNT), 0, int128(AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.TooMuchDebt.selector));
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, AMOUNT);
    }
}

contract TestDecreaseDebt is TestCommon {
    uint128 constant INCREASE_AMOUNT = 20;
    D18 immutable INCREASE_QUANTITY = d18(8);

    function _createAndIncreaseItem() internal {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(INCREASE_AMOUNT, INCREASE_QUANTITY);
        _mockModifyNormalizedDebt(int128(INCREASE_AMOUNT), 0, int128(INCREASE_AMOUNT));
        portfolio.increaseDebt(POOL_A, FIRST_ITEM_ID, INCREASE_AMOUNT);
    }
}

contract TestDecreasesPrincipalDebt is TestDecreaseDebt {
    uint128 constant DECREASE_AMOUNT = 15;
    D18 immutable DECREASE_QUANTITY = d18(6);

    uint128 constant OVER_DECREASE_AMOUNT = INCREASE_AMOUNT + 5;
    D18 immutable OVER_DECREASE_QUANTITY = INCREASE_QUANTITY + d18(3);

    function testSuccess() public {
        _createAndIncreaseItem();

        _mockQuoteForQuantities(DECREASE_AMOUNT, DECREASE_QUANTITY);
        _mockModifyNormalizedDebt(
            -int128(DECREASE_AMOUNT), int128(INCREASE_AMOUNT), int128(INCREASE_AMOUNT - DECREASE_AMOUNT)
        );
        vm.expectEmit();
        emit IPortfolio.DebtDecreased(POOL_A, FIRST_ITEM_ID, DECREASE_AMOUNT, 0);
        portfolio.decreasePrincipalDebt(POOL_A, FIRST_ITEM_ID, DECREASE_AMOUNT);

        assertEq(_getItem(FIRST_ITEM_ID).outstandingQuantity.inner(), (INCREASE_QUANTITY - DECREASE_QUANTITY).inner());
        assertEq(_getItem(FIRST_ITEM_ID).normalizedDebt, int128(INCREASE_AMOUNT - DECREASE_AMOUNT));
    }

    function testErrTooMuchPrincipal() public {
        _createAndIncreaseItem();

        _mockQuoteForQuantities(OVER_DECREASE_AMOUNT, OVER_DECREASE_QUANTITY);
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.TooMuchPrincipal.selector));
        portfolio.decreasePrincipalDebt(POOL_A, FIRST_ITEM_ID, OVER_DECREASE_AMOUNT);
    }

    function testErrTooMuchPrincipalWithoutIncrease() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockQuoteForQuantities(1, d18(1));
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.TooMuchPrincipal.selector));
        portfolio.decreasePrincipalDebt(POOL_A, FIRST_ITEM_ID, 1);
    }
}

contract TestDecreasesInterestDebt is TestDecreaseDebt {
    uint128 constant ITEM_INTEREST = 10;
    uint128 constant INTEREST = 8;
    uint128 constant OVER_INTEREST = ITEM_INTEREST + 1;

    function testSuccess() public {
        _createAndIncreaseItem();

        _mockDebt(int128(INCREASE_AMOUNT), int128(INCREASE_AMOUNT + ITEM_INTEREST));
        _mockQuoteForAmount(INCREASE_QUANTITY, INCREASE_AMOUNT);
        _mockModifyNormalizedDebt(
            -int128(INTEREST), int128(INCREASE_AMOUNT), int128(INCREASE_AMOUNT + ITEM_INTEREST - INTEREST)
        );
        vm.expectEmit();
        emit IPortfolio.DebtDecreased(POOL_A, FIRST_ITEM_ID, 0, INTEREST);
        portfolio.decreaseInterestDebt(POOL_A, FIRST_ITEM_ID, INTEREST);

        assertEq(_getItem(FIRST_ITEM_ID).normalizedDebt, int128(INCREASE_AMOUNT + ITEM_INTEREST - INTEREST));
    }

    function testErrTooMuchInterest() public {
        _createAndIncreaseItem();

        _mockDebt(int128(INCREASE_AMOUNT), int128(INCREASE_AMOUNT + ITEM_INTEREST));
        _mockQuoteForAmount(INCREASE_QUANTITY, INCREASE_AMOUNT);
        _mockModifyNormalizedDebt(
            -int128(OVER_INTEREST), int128(INCREASE_AMOUNT), int128(INCREASE_AMOUNT + ITEM_INTEREST - OVER_INTEREST)
        );
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.TooMuchInterest.selector));
        portfolio.decreaseInterestDebt(POOL_A, FIRST_ITEM_ID, OVER_INTEREST);
    }

    function testErrToMuchInterestWithoutIncrease() public {
        portfolio.create(POOL_A, ITEM_INFO, nfts, TOKEN_ID, OWNER);

        _mockDebt(0, 0);
        _mockQuoteForAmount(d18(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IPortfolio.TooMuchInterest.selector));
        portfolio.decreaseInterestDebt(POOL_A, FIRST_ITEM_ID, 1);
    }
}

contract TestTransferDebt is TestCommon {
    function testSuccess() public {}
}

contract TestItemValuation is TestCommon {
    function testSuccess() public {}
}

contract TestNav is TestCommon {
    function testSuccess() public {}
}
