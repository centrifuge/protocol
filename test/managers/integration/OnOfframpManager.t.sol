// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import "../../spoke/integration/BaseTest.sol";

import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OnOfframpManagerFactory} from "../../../src/managers/OnOfframpManager.sol";
import {IOnOfframpManager} from "../../../src/managers/interfaces/IOnOfframpManager.sol";

abstract contract OnOfframpManagerBaseTest is BaseTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint128 defaultAmount;
    D18 defaultPricePoolPerShare;
    D18 defaultPricePoolPerAsset;
    AssetId assetId;
    ShareClassId defaultTypedShareClassId;

    OnOfframpManagerFactory factory;
    IOnOfframpManager manager;

    address relayer = makeAddr("relayer");
    address receiver = makeAddr("receiver");

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
            address(fullRestrictionsHook)
        );
        spoke.updatePricePoolPerShare(
            POOL_A, defaultTypedShareClassId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spoke.updatePricePoolPerAsset(
            POOL_A, defaultTypedShareClassId, assetId, defaultPricePoolPerShare, uint64(block.timestamp)
        );
        spoke.updateRestriction(
            POOL_A,
            defaultTypedShareClassId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                    user: address(this).toBytes32(), validUntil: MAX_UINT64
                }).serialize()
        );

        factory = new OnOfframpManagerFactory(address(contractUpdater), balanceSheet);
        manager = factory.newManager(POOL_A, defaultTypedShareClassId);
    }

    function _depositIntoBalanceSheet(uint128 amount) internal {
        erc20.mint(address(this), amount);
        erc20.approve(address(balanceSheet), amount);
        balanceSheet.deposit(POOL_A, defaultTypedShareClassId, address(erc20), erc20TokenId, amount);
    }
}

contract OnOfframpManagerIntegrationTest is OnOfframpManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    function testDepositAndWithdrawHappyPath() public {
        uint128 amount = 100;

        // Enable onramp
        vm.prank(address(contractUpdater));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("onramp"), assetId: defaultAssetId, what: bytes32(""), isEnabled: true
                }).serialize()
        );

        // Enable relayer
        vm.prank(address(contractUpdater));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("relayer"), assetId: 0, what: relayer.toBytes32(), isEnabled: true
                }).serialize()
        );

        // Enable offramp destination
        vm.prank(address(contractUpdater));
        manager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateAddress({
                    kind: bytes32("offramp"), assetId: defaultAssetId, what: receiver.toBytes32(), isEnabled: true
                }).serialize()
        );

        // Set manager permissions
        balanceSheet.updateManager(POOL_A, address(manager), true);

        // Mint tokens to manager
        erc20.mint(address(manager), amount);

        // Verify initial state
        assertEq(erc20.balanceOf(address(manager)), amount);
        assertEq(balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);
        assertEq(erc20.balanceOf(receiver), 0);

        // Execute deposit
        manager.deposit(address(erc20), erc20TokenId, amount, address(manager));

        // Verify deposit state changes
        assertEq(erc20.balanceOf(address(manager)), 0);
        assertEq(
            balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), amount
        );

        // Execute withdraw
        vm.prank(relayer);
        manager.withdraw(address(erc20), erc20TokenId, amount, receiver);

        // Verify withdraw state changes
        assertEq(balanceSheet.availableBalanceOf(manager.poolId(), manager.scId(), address(erc20), erc20TokenId), 0);
        assertEq(erc20.balanceOf(receiver), amount);
    }
}
