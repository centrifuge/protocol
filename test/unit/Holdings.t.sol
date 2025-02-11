// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {Holdings} from "src/Holdings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";

PoolId constant POOL_A = PoolId.wrap(42);
ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
AssetId constant ASSET_A = AssetId.wrap(2);
ShareClassId constant NON_SC = ShareClassId.wrap(0);
AssetId constant NON_ASSET = AssetId.wrap(0);
AssetId constant POOL_CURRENCY = AssetId.wrap(23);

contract PoolRegistryMock {
    function currency(PoolId) external pure returns (AssetId) {
        return POOL_CURRENCY;
    }
}

contract TestCommon is Test {
    IPoolRegistry immutable poolRegistry = IPoolRegistry(address(new PoolRegistryMock()));
    IERC7726 immutable itemValuation = IERC7726(address(23));
    IERC7726 immutable customValuation = IERC7726(address(42));
    Holdings holdings = new Holdings(poolRegistry, address(this));

    function mockGetQuote(IERC7726 valuation, uint128 baseAmount, uint128 quoteAmount) public {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(
                IERC7726.getQuote.selector, uint256(baseAmount), ASSET_A.addr(), POOL_CURRENCY.addr()
            ),
            abi.encode(uint256(quoteAmount))
        );
    }

    function setUp() public {
        holdings.allowAsset(POOL_A, ASSET_A, true); // Default asset used in all tests
    }
}

contract TestAllowAsset is TestCommon {
    function testSuccess() public {
        holdings.allowAsset(POOL_A, ASSET_A, false); // Disallow default asset

        vm.expectEmit();
        emit IHoldings.AllowedAsset(POOL_A, ASSET_A, true);
        holdings.allowAsset(POOL_A, ASSET_A, true);

        assertEq(holdings.isAssetAllowed(POOL_A, ASSET_A), true);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.allowAsset(POOL_A, ASSET_A, true);
    }

    function testErrWrongAssetId() public {
        vm.expectRevert(IHoldings.WrongAssetId.selector);
        holdings.allowAsset(POOL_A, NON_ASSET, true);
    }
}

contract TestFile is TestCommon {
    address constant newPoolRegistryAddr = address(42);

    function testSuccess() public {
        vm.expectEmit();
        emit IHoldings.File("poolRegistry", newPoolRegistryAddr);
        holdings.file("poolRegistry", newPoolRegistryAddr);

        assertEq(address(holdings.poolRegistry()), newPoolRegistryAddr);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.file("poolRegistry", newPoolRegistryAddr);
    }

    function testErrFileUnrecognizedWhat() public {
        vm.expectRevert(abi.encodeWithSelector(IHoldings.FileUnrecognizedWhat.selector));
        holdings.file("unrecongnizedWhat", newPoolRegistryAddr);
    }
}

contract TestCreate is TestCommon {
    function testSuccess() public {
        AccountId[] memory accounts = new AccountId[](2);
        accounts[0] = AccountId.wrap(0xAA00 | 0x01);
        accounts[1] = AccountId.wrap(0xBB00 | 0x02);

        vm.expectEmit();
        emit IHoldings.Created(POOL_A, SC_1, ASSET_A, itemValuation);
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, accounts);

        (uint128 amount, uint128 amountValue, IERC7726 valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
        assertEq(amount, 0);
        assertEq(amountValue, 0);

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x01)), 0xAA00 | 0x01);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x02)), 0xBB00 | 0x02);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
    }

    function testErrWrongValuation() public {
        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.create(POOL_A, SC_1, ASSET_A, IERC7726(address(0)), new AccountId[](0));
    }

    function testErrWrongShareClass() public {
        vm.expectRevert(IHoldings.WrongShareClassId.selector);
        holdings.create(POOL_A, NON_SC, ASSET_A, itemValuation, new AccountId[](0));
    }

    function testErrAssetNotAllowed() public {
        vm.expectRevert(IHoldings.AssetNotAllowed.selector);
        holdings.create(POOL_A, SC_1, NON_ASSET, itemValuation, new AccountId[](0));
    }
}

contract TestIncrease is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 20);

        mockGetQuote(customValuation, 8, 50);
        vm.expectEmit();
        emit IHoldings.Increased(POOL_A, SC_1, ASSET_A, customValuation, 8, 50);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 8);

        assertEq(value, 50);

        (uint128 amount, uint128 amountValue, IERC7726 valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 28);
        assertEq(amountValue, 250);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, itemValuation, 0);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, IERC7726(address(0)), 0);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, itemValuation, 0);
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 20);

        mockGetQuote(customValuation, 8, 50);
        vm.expectEmit();
        emit IHoldings.Decreased(POOL_A, SC_1, ASSET_A, customValuation, 8, 50);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, customValuation, 8);

        assertEq(value, 50);

        (uint128 amount, uint128 amountValue, IERC7726 valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 12);
        assertEq(amountValue, 150);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, itemValuation, 0);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, IERC7726(address(0)), 0);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, itemValuation, 0);
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 20);

        vm.expectEmit();
        emit IHoldings.Updated(POOL_A, SC_1, ASSET_A, 50);
        mockGetQuote(itemValuation, 20, 250);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 250);
    }

    function testUpdateLess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 20);

        vm.expectEmit();
        emit IHoldings.Updated(POOL_A, SC_1, ASSET_A, -50);
        mockGetQuote(itemValuation, 20, 150);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, -50);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 150);
    }

    function testUpdateEquals() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, customValuation, 20);

        vm.expectEmit();
        emit IHoldings.Updated(POOL_A, SC_1, ASSET_A, 0);
        mockGetQuote(itemValuation, 20, 200);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 0);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 200);
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.update(POOL_A, SC_1, ASSET_A);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.update(POOL_A, SC_1, ASSET_A);
    }
}

contract TestUpdateValuation is TestCommon {
    IERC7726 immutable newValuation = IERC7726(address(42));

    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.expectEmit();
        emit IHoldings.ValuationUpdated(POOL_A, SC_1, ASSET_A, newValuation);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);

        assertEq(address(holdings.valuation(POOL_A, SC_1, ASSET_A)), address(newValuation));
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, IERC7726(address(0)));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);
    }
}

contract TestSetAccountId is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.expectEmit();
        emit IHoldings.AccountIdSet(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x01)), 0xAA00 | 0x01);
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));
    }
}

contract TestValue is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(itemValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, itemValuation, 20);

        uint128 value = holdings.value(POOL_A, SC_1, ASSET_A);

        assertEq(value, 200);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.value(POOL_A, SC_1, ASSET_A);
    }
}

contract TestAmount is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));
        mockGetQuote(itemValuation, 20, 200);
        holdings.increase(POOL_A, SC_1, ASSET_A, itemValuation, 20);

        uint128 value = holdings.amount(POOL_A, SC_1, ASSET_A);

        assertEq(value, 20);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.amount(POOL_A, SC_1, ASSET_A);
    }
}

contract TestValuation is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, new AccountId[](0));

        IERC7726 valuation = holdings.valuation(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.valuation(POOL_A, SC_1, ASSET_A);
    }
}
