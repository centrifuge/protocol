// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import "../../spoke/integration/BaseTest.sol";

import {IUpdateContract} from "../../../src/spoke/interfaces/IUpdateContract.sol";
import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {IQueueManager} from "../../../src/managers/QueueManager.sol";

abstract contract QueueManagerBaseTest is BaseTest {
    uint64 constant DEFAULT_MIN_DELAY = 3600; // 1 hour
    uint128 constant DEFAULT_AMOUNT = 100_000_000; // 100 USDC

    ShareClassId defaultTypedShareClassId;

    address asset1 = address(erc20);
    address asset2 = address(new ERC20(6));
    address asset3 = address(new ERC20(6));
    AssetId assetId1;
    AssetId assetId2;
    AssetId assetId3;
    address vault1;
    address vault2;
    address vault3;

    address relayer = makeAddr("relayer");
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

        (, address vaultAddress3, uint128 createdAssetId3) = deployVault(
            VaultKind.SyncDepositAsyncRedeem,
            18,
            address(fullRestrictionsHook),
            defaultShareClassId,
            asset3,
            0,
            THIS_CHAIN_ID
        );
        assetId3 = AssetId.wrap(createdAssetId3);
        vault3 = vaultAddress3;
    }
}

contract QueueManagerUpdateContractFailureTests is QueueManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    /// forge-config: default.isolate = true
    function testInvalidUpdater(address notContractUpdater) public {
        vm.assume(notContractUpdater != address(contractUpdater));

        vm.expectRevert(IQueueManager.NotContractUpdater.selector);
        vm.prank(notContractUpdater);
        queueManager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY}).serialize()
        );
    }

    /// forge-config: default.isolate = true
    function testUnknownUpdateContractType() public {
        bytes memory invalidPayload = abi.encode(uint8(255), bytes("invalid"));

        vm.expectRevert(IUpdateContract.UnknownUpdateContractType.selector);
        vm.prank(address(contractUpdater));
        queueManager.update(POOL_A, defaultTypedShareClassId, invalidPayload);
    }
}

contract QueueManagerUpdateContractSuccessTests is QueueManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    /// forge-config: default.isolate = true
    function testUpdateMinDelay(uint64 minDelay) public {
        vm.expectEmit();
        emit IQueueManager.UpdateMinDelay(POOL_A, defaultTypedShareClassId, minDelay);

        vm.prank(address(contractUpdater));
        queueManager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: minDelay}).serialize()
        );

        (uint64 updatedMinDelay, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(updatedMinDelay, minDelay);
        assertEq(lastSync, 0);
    }
}

contract QueueManagerSyncFailureTests is QueueManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    /// forge-config: default.isolate = true
    function testSyncWithNoUpdates() public {
        AssetId[] memory assetIds = new AssetId[](0);

        vm.expectRevert(IQueueManager.NoUpdates.selector);
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);
    }

    /// forge-config: default.isolate = true
    function testMinDelayNotElapsed() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);

        // Set min delay
        vm.prank(address(contractUpdater));
        queueManager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY}).serialize()
        );

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = assetId1;

        // First sync should work (lastSync = 0)
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Second sync immediately should fail due to min delay
        vm.expectRevert(IQueueManager.MinDelayNotElapsed.selector);
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);
    }

    /// forge-config: default.isolate = true
    function testSyncWithDuplicateAssets() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = assetId1;
        assetIds[1] = assetId1; // Duplicate

        vm.expectRevert(IQueueManager.DuplicateAsset.selector);
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);
    }
}

contract QueueManagerSyncSuccessTests is QueueManagerBaseTest {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    /// forge-config: default.isolate = true
    function testSyncAllAssetsAndShares(uint64 amount1, uint64 amount2, uint64 amount3) public {
        vm.assume(amount1 > 0 && amount2 > 0 && amount3 > 0);
        depositSync(vault1, user, amount1);
        depositSync(vault2, user, amount2);
        depositSync(vault3, user, amount3);

        AssetId[] memory assetIds = new AssetId[](3);
        assetIds[0] = assetId1;
        assetIds[1] = assetId2;
        assetIds[2] = assetId3;

        // Expect calls to submitQueuedAssets for each asset
        for (uint256 i = 0; i < assetIds.length; i++) {
            vm.expectCall(
                address(balanceSheet),
                abi.encodeWithSelector(
                    balanceSheet.submitQueuedAssets.selector, POOL_A, defaultTypedShareClassId, assetIds[i], 0
                )
            );
        }

        // Expect call to submitQueuedShares
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, POOL_A, defaultTypedShareClassId, 0)
        );

        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Check that lastSync was updated
        (, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, block.timestamp);
    }

    /// forge-config: default.isolate = true
    function testSyncSomeAssets() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);
        depositSync(vault2, user, DEFAULT_AMOUNT);
        depositSync(vault3, user, DEFAULT_AMOUNT);

        AssetId[] memory assetIds = new AssetId[](2); // Less than queued
        assetIds[0] = assetId1;
        assetIds[1] = assetId2;

        // Expect calls to submitQueuedAssets for each asset
        for (uint256 i = 0; i < assetIds.length; i++) {
            vm.expectCall(
                address(balanceSheet),
                abi.encodeWithSelector(
                    balanceSheet.submitQueuedAssets.selector, POOL_A, defaultTypedShareClassId, assetIds[i], 0
                )
            );
        }

        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Check that lastSync was not updated
        (, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, 0);

        // Check that there are still queued shares and assets
        (uint128 delta,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertGt(delta, 0);
        assertGt(queuedAssetCounter, 0);
    }

    /// forge-config: default.isolate = true
    function testSyncSharesOnly() public {
        AssetId[] memory assetIds = new AssetId[](0);

        centrifugeChain.updateMember(POOL_A.raw(), defaultShareClassId, user, type(uint64).max);
        balanceSheet.issue(POOL_A, defaultTypedShareClassId, user, 1);

        // Expect call to submitQueuedShares
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, POOL_A, defaultTypedShareClassId, 0)
        );

        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Check that lastSync was updated
        (, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, block.timestamp);
    }

    /// forge-config: default.isolate = true
    function testSyncWithZeroMinDelay() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);

        // Set min delay to 0
        vm.prank(address(contractUpdater));
        queueManager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 0}).serialize()
        );

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = assetId1;

        // First sync
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        depositSync(vault1, user, DEFAULT_AMOUNT);

        // Should be able to sync immediately again with minDelay = 0
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);
    }

    /// forge-config: default.isolate = true
    function testMinDelayElapsedAfterTime() public {
        // Set min delay
        vm.prank(address(contractUpdater));
        queueManager.update(
            POOL_A,
            defaultTypedShareClassId,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY}).serialize()
        );

        // Mock balanceSheet.queuedShares to return updates
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.queuedShares.selector, POOL_A, defaultTypedShareClassId),
            abi.encode(uint128(100), uint128(0), uint32(1), uint32(0))
        );

        // Mock multicall to succeed
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(bytes4(keccak256("multicall(bytes[])"))),
            abi.encode(new bytes[](1))
        );

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = AssetId.wrap(1);

        // First sync
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Fast forward time beyond min delay
        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);

        // Second sync should now work
        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);
    }

    /// forge-config: default.isolate = true
    function testSyncWithOnlyNonQueuedAssets() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);

        AssetId[] memory assetIds = new AssetId[](2);
        // No queued amount for these assets
        assetIds[0] = assetId2;
        assetIds[1] = assetId3;

        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Check that lastSync was not updated
        (, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, 0);

        // Check that there are still queued shares and assets
        (uint128 delta,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(POOL_A, defaultTypedShareClassId);
        assertGt(delta, 0);
        assertGt(queuedAssetCounter, 0);
    }

    /// forge-config: default.isolate = true
    function testSyncWithMoreAssetsThanQueued() public {
        depositSync(vault1, user, DEFAULT_AMOUNT);

        AssetId[] memory assetIds = new AssetId[](3);
        assetIds[0] = assetId1;
        assetIds[1] = assetId2;
        assetIds[2] = assetId3;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(
                balanceSheet.submitQueuedAssets.selector, POOL_A, defaultTypedShareClassId, assetId1, 0
            )
        );

        // Expect call to submitQueuedShares
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, POOL_A, defaultTypedShareClassId, 0)
        );

        queueManager.sync(POOL_A, defaultTypedShareClassId, assetIds);

        // Check that lastSync was updated
        (, uint64 lastSync) = queueManager.sc(POOL_A, defaultTypedShareClassId);
        assertEq(lastSync, block.timestamp);
    }
}
