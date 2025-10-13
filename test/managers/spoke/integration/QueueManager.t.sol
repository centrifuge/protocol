// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import "../../../core/spoke/integration/BaseTest.sol";

import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

import {IQueueManager} from "../../../../src/managers/spoke/interfaces/IQueueManager.sol";

abstract contract QueueManagerBaseTest is BaseTest {
    uint128 constant DEFAULT_AMOUNT = 100_000_000;

    ShareClassId defaultTypedShareClassId;

    address asset1 = address(erc20);
    address asset2 = address(new ERC20(6));
    AssetId assetId1;
    AssetId assetId2;
    address vault1;
    address vault2;

    address user = makeAddr("user");

    function setUp() public override {
        super.setUp();

        defaultTypedShareClassId = ShareClassId.wrap(defaultShareClassId);

        balanceSheet.updateManager(POOL_A, address(queueManager), true);

        (, address vaultAddress1, uint128 createdAssetId1) =
            deployVault(VaultKind.SyncDepositAsyncRedeem, 18, defaultShareClassId);
        assetId1 = AssetId.wrap(createdAssetId1);
        vault1 = vaultAddress1;

        (, address vaultAddress2, uint128 createdAssetId2) = deployVault(
            VaultKind.SyncDepositAsyncRedeem,
            18,
            address(fullRestrictionsHook),
            defaultShareClassId,
            asset2,
            0,
            THIS_CHAIN_ID
        );
        assetId2 = AssetId.wrap(createdAssetId2);
        vault2 = vaultAddress2;
    }
}

contract QueueManagerSuccessTest is QueueManagerBaseTest {
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testSuccess() public {
        uint128 extraGasLimit = 500;
        vm.prank(address(contractUpdater));
        queueManager.trustedCall(POOL_A, defaultTypedShareClassId, abi.encode(uint64(0), extraGasLimit));

        depositSync(vault1, user, DEFAULT_AMOUNT);
        depositSync(vault2, user, DEFAULT_AMOUNT / 2);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = assetId1;
        assetIds[1] = assetId2;

        for (uint256 i = 0; i < assetIds.length; i++) {
            vm.expectCall(
                address(balanceSheet),
                abi.encodeWithSelector(
                    balanceSheet.submitQueuedAssets.selector,
                    POOL_A,
                    defaultTypedShareClassId,
                    assetIds[i],
                    extraGasLimit
                )
            );
        }

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(
                balanceSheet.submitQueuedShares.selector, POOL_A, defaultTypedShareClassId, extraGasLimit
            )
        );

        queueManager.sync{value: 0.1 ether}(POOL_A, defaultTypedShareClassId, assetIds, address(this));

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, block.timestamp);
    }
}
