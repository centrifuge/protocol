// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {newItemId, ItemId} from "src/types/ItemId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {Holdings} from "src/Holdings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";

PoolId constant POOL_A = PoolId.wrap(42);
ShareClassId constant SC_1 = ShareClassId.wrap(1);
AssetId constant ASSET_A = AssetId.wrap(address(2));
PoolId constant NON_POOL = PoolId.wrap(0);
ShareClassId constant NON_SC = ShareClassId.wrap(0);
AssetId constant NON_ASSET = AssetId.wrap(address(0));
IERC20Metadata constant POOL_CURRENCY = IERC20Metadata(address(1));

contract PoolRegistryMock {
    function exists(PoolId poolId) external pure returns (bool) {
        return PoolId.unwrap(poolId) != PoolId.unwrap(NON_POOL);
    }

    function currency(PoolId) external pure returns (IERC20Metadata) {
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
                IERC7726.getQuote.selector, uint256(baseAmount), AssetId.unwrap(ASSET_A), address(POOL_CURRENCY)
            ),
            abi.encode(uint256(quoteAmount))
        );
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
        accounts[0] = AccountId.wrap(0xAA00 & 0x01);
        accounts[1] = AccountId.wrap(0xBB00 & 0x02);

        ItemId expectedItemId = newItemId(0);

        vm.expectEmit();
        emit IItemManager.CreatedItem(POOL_A, expectedItemId, itemValuation);
        ItemId itemId = holdings.create(POOL_A, itemValuation, accounts, abi.encode(SC_1, ASSET_A));

        assertEq(ItemId.unwrap(itemId), ItemId.unwrap(expectedItemId));

        (ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount, uint128 amountValue) =
            holdings.item(POOL_A, itemId.index());

        assertEq(ShareClassId.unwrap(scId), ShareClassId.unwrap(SC_1));
        assertEq(AssetId.unwrap(assetId), AssetId.unwrap(ASSET_A));
        assertEq(address(valuation), address(itemValuation));
        assertEq(amount, 0);
        assertEq(amountValue, 0);

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, itemId, 0x01)), 0xAA00 & 0x01);
        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, itemId, 0x02)), 0xBB00 & 0x02);

        ///TODO: check getters

        assertEq(ItemId.unwrap(holdings.itemId(POOL_A, SC_1, ASSET_A)), ItemId.unwrap(itemId));
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
    }

    function testErrNonExistingPool() public {
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, NON_POOL));
        holdings.create(NON_POOL, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
    }

    function testErrWrongValuation() public {
        vm.expectRevert(IItemManager.WrongValuation.selector);
        holdings.create(POOL_A, IERC7726(address(0)), new AccountId[](0), abi.encode(SC_1, ASSET_A));
    }

    function testErrWrongShareClass() public {
        vm.expectRevert(IHoldings.WrongShareClassId.selector);
        holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(NON_SC, ASSET_A));
    }

    function testErrWrongAssetId() public {
        vm.expectRevert(IHoldings.WrongAssetId.selector);
        holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, NON_ASSET));
    }
}

contract TestIncrease is TestCommon {
    function testSuccess() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, itemId, customValuation, 20);

        mockGetQuote(customValuation, 8, 50);
        vm.expectEmit();
        emit IItemManager.ItemIncreased(POOL_A, itemId, customValuation, 8, 50);
        uint128 value = holdings.increase(POOL_A, itemId, customValuation, 8);

        assertEq(value, 50);

        (,, IERC7726 valuation, uint128 amount, uint128 amountValue) = holdings.item(POOL_A, itemId.index());
        assertEq(amount, 28);
        assertEq(amountValue, 250);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.increase(POOL_A, itemId, itemValuation, 0);
    }

    function testErrWrongValuation() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.expectRevert(IItemManager.WrongValuation.selector);
        holdings.increase(POOL_A, itemId, IERC7726(address(0)), 0);
    }

    function testErrItemNotFound() public {
        vm.expectRevert(IItemManager.ItemNotFound.selector);
        holdings.increase(POOL_A, newItemId(0), itemValuation, 0);
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, itemId, customValuation, 20);

        mockGetQuote(customValuation, 8, 50);
        vm.expectEmit();
        emit IItemManager.ItemDecreased(POOL_A, itemId, customValuation, 8, 50);
        uint128 value = holdings.decrease(POOL_A, itemId, customValuation, 8);

        assertEq(value, 50);

        (,, IERC7726 valuation, uint128 amount, uint128 amountValue) = holdings.item(POOL_A, itemId.index());
        assertEq(amount, 12);
        assertEq(amountValue, 150);
        assertEq(address(valuation), address(itemValuation)); // Does not change
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.decrease(POOL_A, itemId, itemValuation, 0);
    }

    function testErrWrongValuation() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.expectRevert(IItemManager.WrongValuation.selector);
        holdings.decrease(POOL_A, itemId, IERC7726(address(0)), 0);
    }

    function testErrItemNotFound() public {
        vm.expectRevert(IItemManager.ItemNotFound.selector);
        holdings.decrease(POOL_A, newItemId(0), itemValuation, 0);
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, itemId, customValuation, 20);

        vm.expectEmit();
        emit IItemManager.ItemUpdated(POOL_A, itemId, 50);
        mockGetQuote(itemValuation, 20, 250);
        int128 diff = holdings.update(POOL_A, itemId);

        assertEq(diff, 50);

        (,,,, uint128 amountValue) = holdings.item(POOL_A, itemId.index());
        assertEq(amountValue, 250);
    }

    function testUpdateLess() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, itemId, customValuation, 20);

        vm.expectEmit();
        emit IItemManager.ItemUpdated(POOL_A, itemId, -50);
        mockGetQuote(itemValuation, 20, 150);
        int128 diff = holdings.update(POOL_A, itemId);

        assertEq(diff, -50);

        (,,,, uint128 amountValue) = holdings.item(POOL_A, itemId.index());
        assertEq(amountValue, 150);
    }

    function testUpdateEquals() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));
        mockGetQuote(customValuation, 20, 200);
        holdings.increase(POOL_A, itemId, customValuation, 20);

        vm.expectEmit();
        emit IItemManager.ItemUpdated(POOL_A, itemId, 0);
        mockGetQuote(itemValuation, 20, 200);
        int128 diff = holdings.update(POOL_A, itemId);

        assertEq(diff, 0);

        (,,,, uint128 amountValue) = holdings.item(POOL_A, itemId.index());
        assertEq(amountValue, 200);
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.update(POOL_A, itemId);
    }

    function testErrItemNotFound() public {
        vm.expectRevert(IItemManager.ItemNotFound.selector);
        holdings.update(POOL_A, newItemId(0));
    }
}

contract TestUpdateValuation is TestCommon {
    IERC7726 immutable newItemValuation = IERC7726(address(42));

    function testSuccess() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.expectEmit();
        emit IItemManager.ValuationUpdated(POOL_A, itemId, newItemValuation);
        holdings.updateValuation(POOL_A, itemId, newItemValuation);

        assertEq(address(holdings.valuation(POOL_A, itemId)), address(newItemValuation));
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.updateValuation(POOL_A, itemId, newItemValuation);
    }

    function testErrWrongValuation() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.expectRevert(IItemManager.WrongValuation.selector);
        holdings.updateValuation(POOL_A, itemId, IERC7726(address(0)));
    }

    function testErrItemNotFound() public {
        vm.expectRevert(IItemManager.ItemNotFound.selector);
        holdings.updateValuation(POOL_A, newItemId(0), newItemValuation);
    }
}

contract TestSetAccountId is TestCommon {
    function testSuccess() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        holdings.setAccountId(POOL_A, itemId, AccountId.wrap(0xAA00 & 0x01));

        assertEq(AccountId.unwrap(holdings.accountId(POOL_A, itemId, 0x01)), 0xAA00 & 0x01);
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, itemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.setAccountId(POOL_A, itemId, AccountId.wrap(0xAA00 & 0x01));
    }

    function testErrItemNotFound() public {
        vm.expectRevert(IItemManager.ItemNotFound.selector);
        holdings.setAccountId(POOL_A, newItemId(0), AccountId.wrap(0xAA00 & 0x01));
    }
}
