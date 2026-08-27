// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {Holdings} from "../../../../src/core/hub/Holdings.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {AccountKind} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
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
            abi.encodeWithSelector(IValuation.getQuote.selector, POOL_A, SC_1, ASSET_A, baseAmount),
            abi.encode(quoteAmount)
        );
    }

    /// @dev A complete, valid 4-slot account set accepted by Holdings.initialize.
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
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        mockGetQuote(itemValuation, 8_000_000, 50_00);
        vm.expectEmit();
        emit IHoldings.Increase(POOL_A, SC_1, ASSET_A, 8_000_000, 50_00);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, 0, 8_000_000);
        assertEq(value, 50_00);

        (uint128 amount, uint128 amountValue, IValuation valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 28_000_000);
        assertEq(amountValue, 250_00);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testIncreaseUninitialized() public {
        // Uninitialized holdings track the amount only; the value is established at initialization
        vm.expectEmit();
        emit IHoldings.Increase(POOL_A, SC_1, ASSET_A, 20_000_000, 0);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);
        assertEq(value, 0);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 20_000_000);
        assertEq(amountValue, 0);
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 0);
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        // The realized decrease is valued at a fresh oracle quote (same price here): 8_000_000 -> 80_00
        mockGetQuote(itemValuation, 8_000_000, 80_00);
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 8_000_000, 80_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 8_000_000);

        assertEq(value, 80_00);

        (uint128 amount, uint128 amountValue, IValuation valuation) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 12_000_000);
        assertEq(amountValue, 120_00);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 0);
    }

    function testDecreaseAmountMoreThanHolding() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 10_000_000, 100_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 10_000_000);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 10_000_000);
        assertEq(amountValue, 100_00);

        // Decrease by more than what we have - the removed amount is clamped to the held amount,
        // so exactly the full carrying value is removed instead of underflowing.
        // The event emits the requested (unclamped) amount and the removed (clamped) value.
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 20_000_000, 100_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        assertEq(value, 100_00);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 0);
        assertEq(finalAmountValue, 0);
    }

    function testDecreaseEmptyHolding() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        // Decreasing an empty holding removes nothing and returns 0
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 5_000_000, 0);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 5_000_000);

        assertEq(value, 0);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 0);
        assertEq(amountValue, 0);
    }

    function testDecreaseAfterMarkdownNeverOverJournals() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 10_000_000, 100_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 10_000_000);

        // Mark the holding down to half its value
        mockGetQuote(itemValuation, 10_000_000, 50_00);
        holdings.update(POOL_A, SC_1, ASSET_A);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 10_000_000);
        assertEq(amountValue, 50_00);

        // A full decrease removes exactly the marked-down carrying value,
        // never more than the holding carries
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 10_000_000, 50_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 10_000_000);

        assertEq(value, 50_00);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 0);
        assertEq(finalAmountValue, 0);
    }

    /// @dev decrease() removes carrying value pro-rata to the realized amount (not at a live quote), so a
    ///      partial decrease removes exactly its share of the stored value regardless of price moves since.
    function testDecreaseRemovesValueProRata() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 10_000_000, 100_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 10_000_000);

        // Price has moved since the increase, but pro-rata reads stored value only: removing 40% of the
        // amount removes 40% of the carrying value (40_00), never the live quote.
        mockGetQuote(itemValuation, 4_000_000, 999_99);
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 4_000_000, 40_00);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 4_000_000);
        assertEq(value, 40_00);

        (uint128 amount, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amount, 6_000_000);
        assertEq(amountValue, 60_00);
    }

    /// @dev A full drain always zeroes the value, even when the price dropped since the last update() (a
    ///      live quote would leave residual value at zero amount). Guards the `amount == 0 => value == 0`
    ///      invariant a live-quote decrease broke.
    function testDecreaseFullDrainZeroesValueDespitePriceDrop() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 100, 100);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 100);

        // Price halves, no update() called. Pro-rata removes the full stored value (100) on a full drain;
        // a live getQuote(100) = 50 would have left 50 behind at amount 0.
        mockGetQuote(itemValuation, 100, 50);
        vm.expectEmit();
        emit IHoldings.Decrease(POOL_A, SC_1, ASSET_A, 100, 100);
        uint128 value = holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 100);
        assertEq(value, 100);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 0);
        assertEq(finalAmountValue, 0);
    }

    function testOverDecreaseNetsAgainstLaterIncrease() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 100, 100);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 100);

        // Second decrease over-shoots the remaining 60 by 60. A running-balance clamp would forget that
        // excess; the cumulative counters carry it so a later increase nets against it.
        mockGetQuote(itemValuation, 40, 40); // first decrease's realized removal (100 -> 60)
        holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 40); // 100 -> 60
        mockGetQuote(itemValuation, 60, 60); // second decrease only realizes the remaining 60
        holdings.decrease(POOL_A, SC_1, ASSET_A, 0, 120); // requests 120, only 60 realized, 60 carried

        (uint128 amountAfterDecrease, uint128 valueAfterDecrease,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountAfterDecrease, 0);
        assertEq(valueAfterDecrease, 0);

        // Increase by 100: 60 pays down the carried over-decrease, so only 40 is realized and valued.
        mockGetQuote(itemValuation, 40, 40);
        vm.expectEmit();
        emit IHoldings.Increase(POOL_A, SC_1, ASSET_A, 100, 40);
        uint128 value = holdings.increase(POOL_A, SC_1, ASSET_A, 0, 100);

        assertEq(value, 40);

        (uint128 finalAmount, uint128 finalAmountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(finalAmount, 40); // 100 - 40 - 120 + 100 = 40, not the 100 a clamp would leave
        assertEq(finalAmountValue, 40);
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        mockGetQuote(itemValuation, 20_000_000, 250_00);
        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, true, 50_00);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50_00);
        assert(isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 250_00);
    }

    function testUpdateLess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        mockGetQuote(itemValuation, 20_000_000, 150_00);
        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, false, 50_00);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 50_00);
        assert(!isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 150_00);
    }

    function testUpdateEquals() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, true, 0);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 0);
        assert(isPositive);

        (, uint128 amountValue,) = holdings.holding(POOL_A, SC_1, ASSET_A);
        assertEq(amountValue, 200_00);
    }

    function testUpdateValuesPreInitializationAmount() public {
        // Increases before initialization carry no value; update() establishes it at the valuation
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());

        mockGetQuote(itemValuation, 20_000_000, 200_00);
        vm.expectEmit();
        emit IHoldings.Update(POOL_A, SC_1, ASSET_A, true, 200_00);
        (bool isPositive, uint128 diff) = holdings.update(POOL_A, SC_1, ASSET_A);

        assertEq(diff, 200_00);
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
        mockGetQuote(itemValuation, 20_000_000, 200_00);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20_000_000);

        uint128 value = holdings.value(POOL_A, SC_1, ASSET_A);

        assertEq(value, 200_00);
    }
}

contract TestAmount is TestCommon {
    function testSuccess() public {
        holdings.initialize(POOL_A, SC_1, ASSET_A, itemValuation, _validAccounts());
        mockGetQuote(itemValuation, 20, 0);
        holdings.increase(POOL_A, SC_1, ASSET_A, 0, 20);

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

/// @dev Deficit = decreasedAmount > increasedAmount (exact equality is not a deficit). Holdings are left
///      uninitialized since amount tracking is valuation-independent.
contract TestDeficitCount is TestCommon {
    uint16 constant CENT_A = 5;
    uint16 constant CENT_B = 6;
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));

    AssetId a1 = newAssetId(CENT_A, 1);
    AssetId a2 = newAssetId(CENT_A, 2);
    AssetId b1 = newAssetId(CENT_B, 1);

    function testEnterDeficitIncrementsAndEmits() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);

        vm.expectEmit();
        emit IHoldings.UpdateDeficitCount(POOL_A, SC_1, CENT_A, 1, 1);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150);

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
        assertEq(holdings.amount(POOL_A, SC_1, a1), 0);

        (uint128 increased, uint128 decreased) = holdings.holdingAmounts(POOL_A, SC_1, a1);
        assertEq(increased, 100);
        assertEq(decreased, 150);
    }

    function testDecreaseFromEmptyEntersDeficit() public {
        vm.expectEmit();
        emit IHoldings.UpdateDeficitCount(POOL_A, SC_1, CENT_A, 1, 1);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 50);

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
    }

    function testDeepenDeficitDoesNotDoubleIncrement() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150); // deficit -50
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 50); // deeper -100, still one holding

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
    }

    function testPartialRefillDoesNotDecrement() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150); // deficit -50
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 30); // still deficit -20

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
    }

    function testExitAtExactEqualityDecrements() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150); // deficit -50

        vm.expectEmit();
        emit IHoldings.UpdateDeficitCount(POOL_A, SC_1, CENT_A, 0, 0);
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 50); // increased == decreased == 150

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 0);
        assertEq(holdings.amount(POOL_A, SC_1, a1), 0);
    }

    /// Decreasing exactly to zero saturates the amount but is not a deficit.
    function testExactZeroHoldingNeverCounted() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 100);

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 0);
        assertEq(holdings.amount(POOL_A, SC_1, a1), 0);
    }

    function testTwoHoldingsSameNetwork() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.increase(POOL_A, SC_1, a2, CENT_A, 100);

        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);

        holdings.decrease(POOL_A, SC_1, a2, CENT_A, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 2);

        holdings.increase(POOL_A, SC_1, a1, CENT_A, 50); // a1 out
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);

        holdings.increase(POOL_A, SC_1, a2, CENT_A, 50); // a2 out
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 0);
    }

    /// @dev The reporting count is per share class, so the same asset in two share classes keeps two separate
    ///      buckets, naming which share class holds the misstated holding.
    function testShareClassesCountIndependently() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.increase(POOL_A, SC_2, a1, CENT_A, 100);

        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1, "deficit lands in its own share class");
        assertEq(holdings.deficitCount(POOL_A, SC_2, CENT_A), 0, "must not leak into a solvent share class");

        holdings.decrease(POOL_A, SC_2, a1, CENT_A, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
        assertEq(holdings.deficitCount(POOL_A, SC_2, CENT_A), 1);

        holdings.increase(POOL_A, SC_1, a1, CENT_A, 50); // SC_1 out, SC_2 still in deficit
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 0);
        assertEq(holdings.deficitCount(POOL_A, SC_2, CENT_A), 1);
    }

    /// @dev The rollup sums every share class on the network, so it stays non-zero while any one of them is in
    ///      deficit. This is what a snapshot hook gates on: the NAV it publishes is pooled across share classes,
    ///      so a deficit under one misstates what a sync on any other would publish.
    function testNetworkRollupSumsShareClasses() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.increase(POOL_A, SC_2, a1, CENT_A, 100);

        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150);
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 1);
        assertEq(holdings.deficitCount(POOL_A, SC_2, CENT_A), 0, "the solvent share class still reports zero");

        holdings.decrease(POOL_A, SC_2, a1, CENT_A, 150);
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 2);

        holdings.increase(POOL_A, SC_1, a1, CENT_A, 50); // SC_1 out, SC_2 still in deficit
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 1, "rollup holds while any share class is short");

        holdings.increase(POOL_A, SC_2, a1, CENT_A, 50); // both out
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 0);
    }

    /// @dev The rollup carries the network the update was reported for, matching the per-share-class bucket.
    function testNetworkRollupSeparatesNetworks() public {
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 50);
        holdings.decrease(POOL_A, SC_2, b1, CENT_B, 50);

        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 1);
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_B), 1);

        holdings.increase(POOL_A, SC_1, a1, CENT_A, 50);
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_A), 0);
        assertEq(holdings.networkDeficitCount(POOL_A, CENT_B), 1, "clearing one network never clears the other");
    }

    /// @dev Two assets in the same share class still share one bucket, counted per misstated holding.
    function testTwoAssetsSameShareClassShareOneBucket() public {
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 50);
        holdings.decrease(POOL_A, SC_1, a2, CENT_A, 50);

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 2);
    }

    function testTwoNetworksIndependent() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.increase(POOL_A, SC_1, b1, CENT_B, 100);

        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_B), 0);

        holdings.decrease(POOL_A, SC_1, b1, CENT_B, 150);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_B), 1);
    }

    /// @dev A carried over-decrease that later nets fully clears the deficit exactly once.
    function testOverDecreaseNetsAndClearsDeficit() public {
        holdings.increase(POOL_A, SC_1, a1, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, a1, CENT_A, 120); // -20, count 1
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1);

        holdings.increase(POOL_A, SC_1, a1, CENT_A, 20); // back to zero, not deficit
        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 0);

        (uint128 increased, uint128 decreased) = holdings.holdingAmounts(POOL_A, SC_1, a1);
        assertEq(increased, 120);
        assertEq(decreased, 120);
    }

    /// @dev Deficit is bucketed by the caller-supplied `centrifugeId` (the network the update is reported
    ///      for), not by the asset's own embedded chain id. This matters for assets whose id carries a
    ///      different (or, for ISO-style currency ids, always-zero) centrifugeId than the network actually
    ///      reporting the holding change, e.g. a currency-reference asset shared across networks.
    function testDeficitBucketedByReportedNetworkNotAssetId() public {
        AssetId isoAsset = newAssetId(840); // ISO 4217 code; centrifugeId() == 0 regardless of network

        holdings.increase(POOL_A, SC_1, isoAsset, CENT_A, 100);
        holdings.decrease(POOL_A, SC_1, isoAsset, CENT_A, 150); // reported for CENT_A, not isoAsset's own (0)

        assertEq(holdings.deficitCount(POOL_A, SC_1, CENT_A), 1, "deficit must land in the reporting network's bucket");
        assertEq(holdings.deficitCount(POOL_A, SC_1, 0), 0, "must not leak into the asset's own embedded centrifugeId");
    }
}
