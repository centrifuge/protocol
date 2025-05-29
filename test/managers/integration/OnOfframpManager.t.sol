// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "test/spoke/BaseTest.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC165} from "src/misc/interfaces/IERC165.sol";
import {IERC7751} from "src/misc/interfaces/IERC7751.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";

import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OnOfframpManager} from "src/managers/OnOfframpManager.sol";
import {IDepositManager, IWithdrawManager} from "src/managers/interfaces/IBalanceSheetManager.sol";
import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";

// TODO: approval tests + factory tests

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

contract OnOfframpManagerUpdateContractFailureTests is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    PoolId public immutable POOL_B = newPoolId(OTHER_CHAIN_ID, 2);

    function testInvalidSource(address notSpoke) public {
        vm.assume(notSpoke != address(spoke));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(notSpoke);
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
    }

    function testInvalidPool() public {
        vm.expectRevert(IOnOfframpManager.InvalidPoolId.selector);
        vm.prank(address(spoke));
        manager.update(
            POOL_B,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("onramp"),
                what: address(erc20).toBytes32(),
                who: bytes32(""),
                where: bytes32(""),
                isEnabled: true
            }).serialize()
        );
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

contract OnOfframpManagerDepositSuccessTests is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testDeposit(uint128 amount) public {
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

        erc20.mint(address(manager), amount);

        assertEq(erc20.balanceOf(address(manager)), amount);
        assertEq(balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);

        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));

        assertEq(erc20.balanceOf(address(manager)), 0);
        assertEq(
            balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), amount
        );
    }
}

contract OnOfframpManagerWithdrawFailureTests is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testNotAllowed(uint128 amount) public {
        vm.expectRevert(IOnOfframpManager.InvalidOfframpDestination.selector);
        manager.withdraw(address(erc20), erc20TokenId, amount, address(this));
    }

    function testNotBalanceSheetManager(uint128 amount) public {
        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("offramp"),
                what: address(erc20).toBytes32(),
                who: address(this).toBytes32(),
                where: makeAddr("receiver").toBytes32(),
                isEnabled: true
            }).serialize()
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        manager.withdraw(address(erc20), erc20TokenId, amount, makeAddr("receiver"));
    }

    function testInsufficientBalance(uint128 amount) public {
        vm.assume(amount > 0);

        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("offramp"),
                what: address(erc20).toBytes32(),
                who: address(this).toBytes32(),
                where: makeAddr("receiver").toBytes32(),
                isEnabled: true
            }).serialize()
        );

        balanceSheet.updateManager(POOL_A, address(manager), true);

        vm.expectPartialRevert(IEscrow.InsufficientBalance.selector);
        manager.withdraw(address(erc20), erc20TokenId, amount, makeAddr("receiver"));
    }
}

contract OnOfframpManagerWithdrawSuccessTests is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testWithdraw(uint128 amount) public {
        vm.assume(amount > 0);

        vm.prank(address(spoke));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                kind: bytes32("offramp"),
                what: address(erc20).toBytes32(),
                who: address(this).toBytes32(),
                where: makeAddr("receiver").toBytes32(),
                isEnabled: true
            }).serialize()
        );

        balanceSheet.updateManager(POOL_A, address(manager), true);

        _depositIntoBalanceSheet(amount);

        assertEq(
            balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), amount
        );
        assertEq(erc20.balanceOf(makeAddr("receiver")), 0);

        manager.withdraw(address(erc20), erc20TokenId, amount, makeAddr("receiver"));

        assertEq(balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);
        assertEq(erc20.balanceOf(makeAddr("receiver")), amount);
    }
}

contract OnOfframpManagerERC165Tests is OnOfframpManagerBaseTest {
    function testERC165Support(bytes4 unsupportedInterfaceId) public view {
        bytes4 erc165 = 0x01ffc9a7;
        bytes4 depositManager = 0xc864037c;
        bytes4 withdrawManager = 0x3e55212a;

        vm.assume(
            unsupportedInterfaceId != erc165 && unsupportedInterfaceId != depositManager
                && unsupportedInterfaceId != withdrawManager
        );

        assertEq(type(IERC165).interfaceId, erc165);
        assertEq(type(IDepositManager).interfaceId, depositManager);
        assertEq(type(IWithdrawManager).interfaceId, withdrawManager);

        assertEq(manager.supportsInterface(erc165), true);
        assertEq(manager.supportsInterface(depositManager), true);
        assertEq(manager.supportsInterface(withdrawManager), true);

        assertEq(manager.supportsInterface(unsupportedInterfaceId), false);
    }
}
