// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "test/spoke/BaseTest.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7751} from "src/misc/interfaces/IERC7751.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";

import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OnOfframpManager} from "src/managers/OnOfframpManager.sol";
import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";

abstract contract OnOfframpManagerBaseTest is BaseTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    OnOfframpManager manager;

    function setUp() public override {
        super.setUp();
        defaultAmount = 100;
        defaultPricePoolPerShare = d18(1, 1);
        defaultPricePoolPerAsset = d18(1, 1);
        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        assetId = spoke.registerAsset{value: 0.1 ether}(OTHER_CHAIN_ID, address(erc20), erc20TokenId);
        spoke.addPool(POOL_A);
        spoke.addShareClass(
            POOL_A,
            defaultTypedShareClassId,
            "testShareClass",
            "tsc",
            defaultDecimals,
            bytes32(""),
            fullRestrictionsHook
        );
        spoke.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare.raw(), uint64(block.timestamp)
        );
        spoke.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: address(this).toBytes32(),
                validUntil: MAX_UINT64
            }).serialize()
        );

        manager = new OnOfframpManager(POOL_A, defaultTypedShareClassId, address(spoke), balanceSheet);
        balanceSheet.setQueue(POOL_A, defaultTypedShareClassId, true);
    }

    function _depositIntoBalanceSheet(uint128 amount) internal {
        erc20.mint(address(this), amount);
        erc20.approve(address(balanceSheet), amount);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, amount);
    }
}

contract OnOfframpManagerDepositFailureTests is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOfframpManager.NotAllowedOnrampAsset.selector);
        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));
    }

    function testNotBalanceSheetManager(uint128 amount) public {
        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("onramp"),
                what: address(erc20).toBytes32(),
                who: bytes32(""),
                where: bytes32(""),
                isEnabled: true
            }).serialize()
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));
    }

    function testInsufficientBalance(uint128 amount) public {
        vm.assume(amount > 0);

        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("onramp"),
                what: address(erc20).toBytes32(),
                who: bytes32(""),
                where: bytes32(""),
                isEnabled: true
            }).serialize()
        );

        balanceSheet.updateManager(POOL_A, address(manager), true);

        vm.expectPartialRevert(IERC7751.WrappedError.selector);
        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));
    }
}

contract OnOfframpManagerWithdrawFailureTests is OnOfframpManagerBaseTest {
    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOfframpManager.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), erc20TokenId, amount, address(this));
    }
}
