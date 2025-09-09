// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {TransientStorageLib} from "../../../src/misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {QueueManager} from "../../../src/managers/QueueManager.sol";
import {IQueueManager} from "../../../src/managers/interfaces/IQueueManager.sol";

import {IBalanceSheet} from "../../../src/spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../../../src/spoke/interfaces/IUpdateContract.sol";
import {UpdateContractMessageLib} from "../../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {Multicall} from "../../../src/misc/Multicall.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract MockBalanceSheet is Multicall {
    struct ShareQueueAmount {
        uint128 delta;
        bool isPositive;
        uint32 queuedAssetCounter;
        uint64 nonce;
    }

    struct AssetQueueAmount {
        uint128 deposits;
        uint128 withdrawals;
    }

    mapping(PoolId => mapping(ShareClassId => ShareQueueAmount)) public queuedShares;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId => AssetQueueAmount))) public queuedAssets;

    function submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 extraGasLimit) external {}

    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit) external {}
}

contract QueueManagerTest is Test {
    using CastLib for *;
    using UpdateContractMessageLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("2"));
    AssetId constant ASSET_1 = AssetId.wrap(1);
    AssetId constant ASSET_2 = AssetId.wrap(2);
    AssetId constant ASSET_3 = AssetId.wrap(3);

    uint64 constant DEFAULT_MIN_DELAY = 3600;
    uint128 constant DEFAULT_EXTRA_GAS = 1000;
    uint128 constant DEFAULT_AMOUNT = 100_000_000;

    IBalanceSheet balanceSheet = IBalanceSheet(address(new MockBalanceSheet()));

    address contractUpdater = makeAddr("contractUpdater");
    address unauthorized = makeAddr("unauthorized");

    QueueManager queueManager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {}

    function _deployManager() internal {
        queueManager = new QueueManager(contractUpdater, balanceSheet);
    }

    function _mockQueuedShares(
        PoolId poolId,
        ShareClassId scId,
        uint128 delta,
        bool isPositive,
        uint32 queuedAssetCounter
    ) internal {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.queuedShares.selector, poolId, scId),
            abi.encode(delta, isPositive, queuedAssetCounter, 0)
        );
    }

    function _mockQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 deposits, uint128 withdrawals)
        internal
    {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.queuedAssets.selector, poolId, scId, assetId),
            abi.encode(deposits, withdrawals)
        );
    }
}

contract QueueManagerConstructorTest is QueueManagerTest {
    function testConstructor() public view {
        assertEq(queueManager.contractUpdater(), contractUpdater);
        assertEq(address(queueManager.balanceSheet()), address(balanceSheet));
    }
}

contract QueueManagerUpdateContractFailureTests is QueueManagerTest {
    using UpdateContractMessageLib for *;

    function testInvalidUpdater(address notContractUpdater) public {
        vm.assume(notContractUpdater != contractUpdater);

        vm.expectRevert(IQueueManager.NotContractUpdater.selector);
        vm.prank(notContractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );
    }

    function testUnknownUpdateContractType() public {
        bytes memory invalidPayload = abi.encode(uint8(255), bytes("invalid"));

        vm.expectRevert(IUpdateContract.UnknownUpdateContractType.selector);
        vm.prank(contractUpdater);
        queueManager.update(POOL_A, SC_1, invalidPayload);
    }
}

contract QueueManagerUpdateContractSuccessTests is QueueManagerTest {
    using UpdateContractMessageLib for *;

    function testUpdateQueueConfig() public {
        vm.expectEmit();
        emit IQueueManager.UpdateQueueConfig(POOL_A, SC_1, DEFAULT_MIN_DELAY, DEFAULT_EXTRA_GAS);

        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({
                minDelay: DEFAULT_MIN_DELAY,
                extraGasLimit: DEFAULT_EXTRA_GAS
            }).serialize()
        );

        (uint64 minDelay, uint64 lastSync, uint128 extraGasLimit) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(minDelay, DEFAULT_MIN_DELAY);
        assertEq(lastSync, 0);
        assertEq(extraGasLimit, DEFAULT_EXTRA_GAS);
    }

    function testUpdateMultipleShareClasses() public {
        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 1000, extraGasLimit: 500}).serialize()
        );

        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_2,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 2000, extraGasLimit: 1000}).serialize()
        );

        (uint64 minDelay1,, uint128 extraGasLimit1) = queueManager.scQueueState(POOL_A, SC_1);
        (uint64 minDelay2,, uint128 extraGasLimit2) = queueManager.scQueueState(POOL_A, SC_2);

        assertEq(minDelay1, 1000);
        assertEq(extraGasLimit1, 500);
        assertEq(minDelay2, 2000);
        assertEq(extraGasLimit2, 1000);
    }
}

contract QueueManagerSyncFailureTests is QueueManagerTest {
    using UpdateContractMessageLib for *;

    function testSyncWithNoUpdates() public {
        AssetId[] memory assetIds = new AssetId[](0);

        vm.expectRevert(IQueueManager.NoUpdates.selector);
        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testMinDelayNotElapsed() public {
        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync(POOL_A, SC_1, assetIds);

        vm.expectRevert(IQueueManager.MinDelayNotElapsed.selector);
        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testSyncWithTooManyAssets() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](257);
        for (uint128 i = 0; i < 257; i++) {
            assetIds[i] = AssetId.wrap(i + 1);
        }

        vm.expectRevert(IQueueManager.TooManyAssets.selector);
        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testSyncWithNoQueuedData() public {
        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        vm.expectRevert(IQueueManager.NoUpdates.selector);
        queueManager.sync(POOL_A, SC_1, assetIds);
    }
}

contract QueueManagerSyncSuccessTests is QueueManagerTest {
    using UpdateContractMessageLib for *;

    function testSyncAllAssetsAndShares() public {
        _mockQueuedShares(POOL_A, SC_1, 300, true, 3);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_2, 200, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_3, 300, 0);

        AssetId[] memory assetIds = new AssetId[](3);
        assetIds[0] = ASSET_1;
        assetIds[1] = ASSET_2;
        assetIds[2] = ASSET_3;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0)
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_2, 0)
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_3, 0)
        );
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0)
        );

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncSomeAssets() public {
        _mockQueuedShares(POOL_A, SC_1, 300, true, 3);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_2, 200, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_3, 300, 0);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = ASSET_1;
        assetIds[1] = ASSET_2;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0)
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_2, 0)
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_3, 0),
            0
        );

        // Expect submitQueuedShares not to be called
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0), 0
        );

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, 0);
    }

    function testSyncWithMaxAssets() public {
        AssetId[] memory assetIds = new AssetId[](256);

        _mockQueuedShares(POOL_A, SC_1, 256, true, 256);

        for (uint128 i = 0; i < 256; i++) {
            AssetId assetId = AssetId.wrap(i + 1);
            assetIds[i] = assetId;
            _mockQueuedAssets(POOL_A, SC_1, assetId, 1, 0);
        }

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncSharesOnly() public {
        AssetId[] memory assetIds = new AssetId[](0);

        _mockQueuedShares(POOL_A, SC_1, 100, true, 0);

        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0)
        );

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncWithZeroMinDelay() public {
        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 0, extraGasLimit: 0}).serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync(POOL_A, SC_1, assetIds);

        // Should be able to sync immediately again
        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testMinDelayElapsedAfterTime() public {
        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync(POOL_A, SC_1, assetIds);

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);

        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testSyncWithExtraGasLimit(uint128 extraGasLimit) public {
        vm.assume(extraGasLimit <= 50_000_000);

        vm.prank(contractUpdater);
        queueManager.update(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 0, extraGasLimit: extraGasLimit}).serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, extraGasLimit)
        );

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, extraGasLimit)
        );

        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testSyncWithDuplicateAssets() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = ASSET_1;
        assetIds[1] = ASSET_1;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0),
            1
        );

        queueManager.sync(POOL_A, SC_1, assetIds);
    }

    function testSyncWithMoreAssetsThanQueued() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_2, 0, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_3, 0, 0);

        AssetId[] memory assetIds = new AssetId[](3);
        assetIds[0] = ASSET_1;
        assetIds[1] = ASSET_2;
        assetIds[2] = ASSET_3;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0)
        );

        // No calls for non-queued assets
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_2, 0),
            0
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_3, 0),
            0
        );

        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0)
        );

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncWithOnlyNonQueuedAssets() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_2, 0, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_3, 0, 0);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = ASSET_2;
        assetIds[1] = ASSET_3;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0),
            0
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_2, 0),
            0
        );
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_3, 0),
            0
        );
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0), 0
        );

        queueManager.sync(POOL_A, SC_1, assetIds);

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, 0);
    }

    function testSyncMultiplePools() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedShares(POOL_B, SC_2, 200, true, 1);
        _mockQueuedAssets(POOL_B, SC_2, ASSET_1, 200, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_1, 0)
        );
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0)
        );

        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_B, SC_2, ASSET_1, 0)
        );
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_B, SC_2, 0)
        );

        queueManager.sync(POOL_A, SC_1, assetIds);
        (, uint64 lastSyncA,) = queueManager.scQueueState(POOL_A, SC_1);

        assertEq(lastSyncA, block.timestamp);

        queueManager.sync(POOL_B, SC_2, assetIds);
        (, uint64 lastSyncB,) = queueManager.scQueueState(POOL_B, SC_2);

        assertEq(lastSyncB, block.timestamp);
    }
}
