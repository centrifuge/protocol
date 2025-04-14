// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {d18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";

PoolId constant POOL_A = PoolId.wrap(42);
ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
AssetId constant ASSET_A = AssetId.wrap(2);
ShareClassId constant NON_SC = ShareClassId.wrap(0);
AssetId constant NON_ASSET = AssetId.wrap(0);
AssetId constant POOL_CURRENCY = AssetId.wrap(23);

contract HubRegistryMock {
    function currency(PoolId) external pure returns (AssetId) {
        return POOL_CURRENCY;
    }
}

contract TestCommon is Test {
    IHubRegistry immutable hubRegistry = IHubRegistry(address(new HubRegistryMock()));
    IERC7726 immutable itemValuation = IERC7726(address(23));
    IERC7726 immutable customValuation = IERC7726(address(42));
    Holdings holdings = new Holdings(hubRegistry, address(this));

    function mockGetQuote(IERC7726 valuation, uint128 baseAmount, uint128 quoteAmount) public {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(
                IERC7726.getQuote.selector, uint256(baseAmount), ASSET_A.addr(), POOL_CURRENCY.addr()
            ),
            abi.encode(uint256(quoteAmount))
        );
    }
}

contract TestFile is TestCommon {
    address constant newHubRegistryAddr = address(42);

    function testSuccess() public {
        vm.expectEmit();
        emit IHoldings.File("hubRegistry", newHubRegistryAddr);
        holdings.file("hubRegistry", newHubRegistryAddr);

        assertEq(address(holdings.hubRegistry()), newHubRegistryAddr);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.file("hubRegistry", newHubRegistryAddr);
    }

    function testErrFileUnrecognizedWhat() public {
        vm.expectRevert(abi.encodeWithSelector(IHoldings.FileUnrecognizedWhat.selector));
        holdings.file("unrecongnizedWhat", newHubRegistryAddr);
    }
}

contract TestCreate is TestCommon {
    function testSuccess() public {
        AccountId[] memory accounts = new AccountId[](2);
        accounts[0] = AccountId.wrap(0xAA00 | 0x01);
        accounts[1] = AccountId.wrap(0xBB00 | 0x02);

        vm.expectEmit();
        emit IHoldings.Create(POOL_A, SC_1, ASSET_A, itemValuation, false);
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, accounts);

        (uint128 amount, uint128 amountValue, IERC7726 valuation, bool isLiability) =
            holdings.holding(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
        assertEq(amount, 0);
        assertEq(amountValue, 0);
        assertEq(isLiability, false);

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x01)), 0xAA00 | 0x01);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x02)), 0xBB00 | 0x02);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
    }

    function testErrWrongValuation() public {
        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.create(POOL_A, SC_1, ASSET_A, IERC7726(address(0)), false, new AccountId[](0));
    }

    function testErrWrongShareClass() public {
        vm.expectRevert(IHoldings.WrongShareClassId.selector);
        holdings.create(POOL_A, NON_SC, ASSET_A, itemValuation, false, new AccountId[](0));
    }
}

contract TestIncrease is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        vm.expectEmit();
        emit IHoldings.Increase(POOL_A, SC_1, ASSET_A, d18(50, 8), 8, 50);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, d18(50, 8), 8);

        assertEq(value, 50);

        (uint128 amount, uint128 amountValue, IERC7726 valuation,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 28);
        assertEq(amountValue, 250);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, d18(50, 8), 8, 50);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, d18(50, 8), 8);

        assertEq(value, 50);

        (uint128 amount, uint128 amountValue, IERC7726 valuation,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 12);
        assertEq(amountValue, 150);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, 50);
        mockGetQuote(itemValuation, 20, 250);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50);

        (, uint128 amountValue,,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 250);
    }

    function testUpdateLess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, -50);
        mockGetQuote(itemValuation, 20, 150);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, -50);

        (, uint128 amountValue,,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 150);
    }

    function testUpdateEquals() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, 0);
        mockGetQuote(itemValuation, 20, 200);
        int128 diff = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 0);

        (, uint128 amountValue,,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 200);
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

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
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.expectEmit();
        emit IHoldings.UpdateValuation(POOL_A, SC_1, ASSET_A, newValuation);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);

        assertEq(address(holdings.valuation(POOL_A, SC_1, ASSET_A)), address(newValuation));
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);
    }

    function testErrWrongValuation() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

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
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        vm.expectEmit();
        emit IHoldings.SetAccountId(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, AccountId.wrap(0xAA00 | 0x01));

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 0x01)), 0xAA00 | 0x01);
    }

    function testErrNotAuthorized() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

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
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

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
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

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
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        IERC7726 valuation = holdings.valuation(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.valuation(POOL_A, SC_1, ASSET_A);
    }
}

contract TestExists is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, false, new AccountId[](0));

        assert(holdings.exists(POOL_A, SC_1, ASSET_A));
        assert(!holdings.exists(POOL_A, SC_1, POOL_CURRENCY));
    }
}

contract TestLiability is TestCommon {
    function testSuccess() public {
        holdings.create(POOL_A, SC_1, ASSET_A, itemValuation, true, new AccountId[](0));

        assert(holdings.isLiability(POOL_A, SC_1, ASSET_A));
    }
}
