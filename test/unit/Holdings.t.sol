// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {newItemId, ItemId} from "src/types/ItemId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {Holdings, Item} from "src/Holdings.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IHoldings} from "src/interfaces/IHoldings.sol";

PoolId constant POOL_A = PoolId.wrap(42);
ShareClassId constant SC_1 = ShareClassId.wrap(1);
AssetId constant ASSET_A = AssetId.wrap(address(2));
PoolId constant NON_POOL = PoolId.wrap(0);
ShareClassId constant NON_SC = ShareClassId.wrap(0);
AssetId constant NON_ASSET = AssetId.wrap(address(0));

contract PoolRegistryMock {
    function exists(PoolId poolId) external pure returns (bool) {
        return PoolId.unwrap(poolId) != PoolId.unwrap(NON_POOL);
    }
}

contract TestCommon is Test {
    IPoolRegistry immutable poolRegistry = IPoolRegistry(address(new PoolRegistryMock()));
    IERC7726 immutable itemValuation = IERC7726(address(23));
    Holdings holdings = new Holdings(poolRegistry, address(this));
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
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestDecrease is TestCommon {
    function testSuccess() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrWrongValuation() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestUpdate is TestCommon {
    function testUpdateMore() public {
        //TODO
    }

    function testUpdateLess() public {
        //TODO
    }

    function testUpdateEquals() public {
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}

contract TestUpdateValuation is TestCommon {
    IERC7726 immutable newItemValuation = IERC7726(address(42));

    function testSuccess() public {
        ItemId itemId = holdings.create(POOL_A, newItemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.expectEmit();
        emit IItemManager.ValuationUpdated(POOL_A, itemId, newItemValuation);
        holdings.updateValuation(POOL_A, itemId, newItemValuation);

        assertEq(address(holdings.valuation(POOL_A, itemId)), address(newItemValuation));
    }

    function testErrNotAuthorized() public {
        ItemId itemId = holdings.create(POOL_A, newItemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        holdings.updateValuation(POOL_A, itemId, newItemValuation);
    }

    function testErrWrongValuation() public {
        ItemId itemId = holdings.create(POOL_A, newItemValuation, new AccountId[](0), abi.encode(SC_1, ASSET_A));

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
        //TODO
    }

    function testErrNotAuthorized() public {
        //TODO
    }

    function testErrItemNotFound() public {
        //TODO
    }
}
