// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {Holdings} from "../../../../src/core/hub/Holdings.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {AccountKind} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../../../src/core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";

import "forge-std/Test.sol";

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

    function decimals(PoolId) external pure returns (uint8) {
        return 2;
    }

    function decimals(AssetId) external pure returns (uint8) {
        return 6;
    }
}

contract TestCommon is Test {
    IHubRegistry immutable hubRegistry = IHubRegistry(address(new HubRegistryMock()));
    IValuation immutable itemValuation = IValuation(address(23));
    Holdings holdings = new Holdings(hubRegistry, address(this));

    function mockGetQuote(IValuation valuation, uint128 baseAmount, uint128 quoteAmount) public {
        vm.mockCall(
            address(valuation),
            abi.encodeWithSelector(IValuation.getQuote.selector, POOL_A, SC_1, ASSET_A, uint256(baseAmount)),
            abi.encode(uint256(quoteAmount))
        );
    }

    /// @dev A complete, valid 4-slot account set (distinct debit) accepted by Holdings.initialize.
    function _validAccounts() internal pure returns (AccountId[4] memory accounts) {
        accounts[0] = AccountId.wrap(0xAA00);
        accounts[1] = AccountId.wrap(0xBB00);
        accounts[2] = AccountId.wrap(0xCC00);
        accounts[3] = AccountId.wrap(0xDD00);
    }
}

contract TestInitialize is TestCommon {
    function testSuccess() public {
        AccountId[4] memory accounts = _validAccounts();

        vm.expectEmit();
        emit IHoldings.Initialize(POOL_A, SC_1, ASSET_A, itemValuation, accounts);
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, accounts);

        (uint128 amount, uint128 amountValue, IValuation valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
        assertEq(amount, 0);
        assertEq(amountValue, 0);

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, uint8(AccountKind.AmountDebit))), 0xAA00);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, uint8(AccountKind.AmountCredit))), 0xBB00);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, uint8(AccountKind.ValueIncrease))), 0xCC00);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, uint8(AccountKind.ValueDecrease))), 0xDD00);
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
    }

    function testErrWrongValuation() public {
        vm.expectRevert(IHoldings.WrongValuation.selector);
        holdings.initialize(POOL_A, SC_1, ASSET_A, IValuation(address(0)), _validAccounts());
    }

    function testErrWrongShareClass() public {
        vm.expectRevert(IHoldings.WrongShareClassId.selector);
        holdings.initialize(POOL_A, NON_SC, ASSET_A, itemValuation, _validAccounts());
    }

    function testErrAlreadyInitialized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.expectRevert(IHoldings.AlreadyInitialized.selector);
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
    }
}

contract TestIncrease is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        vm.expectEmit();
        emit IHoldings.Increase(POOL_A, SC_1, ASSET_A, d18(50, 8), 8_000_000, 50_00);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, d18(50, 8), 8_000_000);
        assertEq(value, 50_00);

        (uint128 amount, uint128 amountValue, IValuation valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 28_000_000);
        assertEq(amountValue, 250_00);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, d18(50, 8), 8_000_000, 50_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, d18(50, 8), 8_000_000);

        assertEq(value, 50_00);

        (uint128 amount, uint128 amountValue, IValuation valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 12_000_000);
        assertEq(amountValue, 150_00);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, d18(1, 1), 0);
    }

    function testDecreaseAmountMoreThanHolding() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        holdings.increase(POOL_A, SC_1, ASSET_A, d18(10, 1), 10_000_000);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 10_000_000);
        assertEq(amountValue, 100_00);

        // Decrease by more than what we have - should clamp amount to 0 instead of underflowing
        // Should emit the original unclamped amount and value
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, d18(4, 1), 20_000_000, 80_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, d18(4, 1), 20_000_000);

        assertEq(value, 80_00);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 0);
        assertEq(finalAmountValue, 20_00);
    }

    function testDecreaseValueMoreThanHolding() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        holdings.increase(POOL_A, SC_1, ASSET_A, d18(10, 1), 10_000_000);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 10_000_000);
        assertEq(amountValue, 100_00);

        // Decrease with a higher price, creating more value than we have - should clamp value to 0
        // Should emit the original unclamped amount and value
        // And return the unclamped value
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, d18(20, 1), 6_000_000, 120_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, d18(20, 1), 6_000_000);

        assertEq(value, 120_00);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 4_000_000);
        assertEq(finalAmountValue, 0);
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, true, 50_00);
        mockGetQuote(itemValuation, 20_000_000, 250_00);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50_00);
        assert(isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 250_00);
    }

    function testUpdateLess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, false, 50_00);
        mockGetQuote(itemValuation, 20_000_000, 150_00);

        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50_00);
        assert(!isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 150_00);
    }

    function testUpdateEquals() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, true, 0);
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 0);
        assert(isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 200_00);
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

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
    IValuation immutable newValuation = IValuation(address(42));

    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.expectEmit();
        emit IHoldings.UpdateValuation(POOL_A, SC_1, ASSET_A, newValuation);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);

        assertEq(address(holdings.valuation(POOL_A, SC_1, ASSET_A)), address(newValuation));
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.updateValuation(POOL_A, SC_1, ASSET_A, newValuation);
    }
}

contract TestSetAccountId is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.expectEmit();
        emit IHoldings.SetAccountId(POOL_A, SC_1, ASSET_A, 1, AccountId.wrap(0xAA00));
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, 1, AccountId.wrap(0xAA00));

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, SC_1, ASSET_A, 1)), 0xAA00);
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, 1, AccountId.wrap(0xAA00));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.setAccountId(POOL_A, SC_1, ASSET_A, 1, AccountId.wrap(0xAA00));
    }
}

contract TestValue is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20_000_000);

        uint128 value = holdings.value(POOL_A, SC_1, ASSET_A);

        assertEq(value, 200_00);
    }
}

contract TestAmount is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        holdings.increase(POOL_A, SC_1, ASSET_A, d18(200, 20), 20);

        uint128 value = holdings.amount(POOL_A, SC_1, ASSET_A);

        assertEq(value, 20);
    }
}

contract TestValuation is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        IValuation valuation = holdings.valuation(POOL_A, SC_1, ASSET_A);

        assertEq(address(valuation), address(itemValuation));
    }

    function testErrHoldingNotFound() public {
        vm.expectRevert(IHoldings.HoldingNotFound.selector);
        holdings.valuation(POOL_A, SC_1, ASSET_A);
    }
}

contract TestExists is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        assert(holdings.isInitialized(POOL_A, SC_1, ASSET_A));
        assert(!holdings.isInitialized(POOL_A, SC_1, POOL_CURRENCY));
    }
}
