// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {IGateway} from "../../../../src/core/interfaces/IGateway.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IContractUpdate} from "../../../../src/core/interfaces/IContractUpdate.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";
import {IBatchedMulticall} from "../../../../src/core/interfaces/IBatchedMulticall.sol";

import {QueueManager} from "../../../../src/managers/spoke/QueueManager.sol";
import {IQueueManager} from "../../../../src/managers/spoke/interfaces/IQueueManager.sol";

import "forge-std/Test.sol";

import {UpdateContractMessageLib} from "../../../../src/libraries/UpdateContractMessageLib.sol";

contract IsContract {}

contract MockGateway {
    function withBatch(bytes memory data, address) external payable returns (uint256 cost) {
        (bool success, bytes memory returnData) = msg.sender.call(data);
        if (!success) {
            uint256 length = returnData.length;
            require(length != 0, "Empty revert");

            assembly ("memory-safe") {
                revert(add(32, returnData), length)
            }
        }
        return 0;
    }
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

    address balanceSheet = address(new IsContract());
    address gateway = address(new MockGateway());

    address contractUpdater = makeAddr("contractUpdater");
    address unauthorized = makeAddr("unauthorized");
    address auth = makeAddr("auth");

    QueueManager queueManager;

    function setUp() public virtual {
        _setupMocks();
        _deployManager();
    }

    function _setupMocks() internal {
        vm.mockCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBatchedMulticall.gateway.selector),
            abi.encode(IGateway(gateway))
        );
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector), abi.encode(0));
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector), abi.encode(0));
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.queuedAssets.selector), abi.encode(0, 0));
        vm.mockCall(
            balanceSheet, abi.encodeWithSelector(IBalanceSheet.queuedShares.selector), abi.encode(0, false, 0, 0)
        );
        vm.mockCall(gateway, abi.encodeWithSelector(IGateway.lockCallback.selector), abi.encode(address(this)));
    }

    function _deployManager() internal {
        queueManager = new QueueManager(contractUpdater, IBalanceSheet(address(balanceSheet)), auth);
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

    function _expectSubmitAssets(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, poolId, scId, assetId, 0, address(0))
        );
    }

    function _expectSubmitShares(PoolId poolId, ShareClassId scId) internal {
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, poolId, scId, 0, address(0))
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
        queueManager.trustedCall(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );
    }

    function testUnknownUpdateContractType() public {
        bytes memory invalidPayload = abi.encode(uint8(255), bytes("invalid"));

        vm.expectRevert(IContractUpdate.UnknownUpdateContractType.selector);
        vm.prank(contractUpdater);
        queueManager.trustedCall(POOL_A, SC_1, invalidPayload);
    }
}

contract QueueManagerUpdateContractSuccessTests is QueueManagerTest {
    using UpdateContractMessageLib for *;

    function testUpdateQueueConfig() public {
        vm.expectEmit();
        emit IQueueManager.UpdateQueueConfig(POOL_A, SC_1, DEFAULT_MIN_DELAY, DEFAULT_EXTRA_GAS);

        vm.prank(contractUpdater);
        queueManager.trustedCall(
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
        queueManager.trustedCall(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 1000, extraGasLimit: 500}).serialize()
        );

        vm.prank(contractUpdater);
        queueManager.trustedCall(
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
        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
    }

    function testMinDelayNotElapsed() public {
        vm.prank(contractUpdater);
        queueManager.trustedCall(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        vm.expectRevert(IQueueManager.MinDelayNotElapsed.selector);
        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
    }

    function testSyncWithNoQueuedData() public {
        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        vm.expectRevert(IQueueManager.NoUpdates.selector);
        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
    }

    function testSyncWithOnlyNonQueuedAssets() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_2, 0, 0);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_3, 0, 0);

        AssetId[] memory assetIds = new AssetId[](2);
        assetIds[0] = ASSET_2;
        assetIds[1] = ASSET_3;

        vm.expectRevert(IQueueManager.NoUpdates.selector);
        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
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

        _expectSubmitAssets(POOL_A, SC_1, ASSET_1);
        _expectSubmitAssets(POOL_A, SC_1, ASSET_2);
        _expectSubmitAssets(POOL_A, SC_1, ASSET_3);
        _expectSubmitShares(POOL_A, SC_1);

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

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

        _expectSubmitAssets(POOL_A, SC_1, ASSET_1);
        _expectSubmitAssets(POOL_A, SC_1, ASSET_2);
        // Expect submitQueuedAssets not to be called for ASSET_3
        vm.expectCall(
            address(balanceSheet),
            abi.encodeWithSelector(IBalanceSheet.submitQueuedAssets.selector, POOL_A, SC_1, ASSET_3, 0),
            0
        );

        // Expect submitQueuedShares not to be called
        vm.expectCall(
            address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.submitQueuedShares.selector, POOL_A, SC_1, 0), 0
        );

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

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

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncSharesOnly() public {
        AssetId[] memory assetIds = new AssetId[](0);

        _mockQueuedShares(POOL_A, SC_1, 100, true, 0);

        _expectSubmitShares(POOL_A, SC_1);

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    /// forge-config: default.isolate = true
    function testSyncWithZeroMinDelay() public {
        vm.prank(contractUpdater);
        queueManager.trustedCall(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: 0, extraGasLimit: 0}).serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        // Should be able to sync immediately again
        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
    }

    /// forge-config: default.isolate = true
    function testMinDelayElapsedAfterTime() public {
        vm.prank(contractUpdater);
        queueManager.trustedCall(
            POOL_A,
            SC_1,
            UpdateContractMessageLib.UpdateContractUpdateQueue({minDelay: DEFAULT_MIN_DELAY, extraGasLimit: 0})
                .serialize()
        );

        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        vm.warp(block.timestamp + DEFAULT_MIN_DELAY + 1);

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
    }

    function testSyncWithExtraGasLimit(uint128 extraGasLimit) public {
        vm.assume(extraGasLimit <= 50_000_000);

        vm.prank(contractUpdater);
        queueManager.trustedCall(
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

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
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

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
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

        _expectSubmitAssets(POOL_A, SC_1, ASSET_1);

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

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));

        (, uint64 lastSync,) = queueManager.scQueueState(POOL_A, SC_1);
        assertEq(lastSync, block.timestamp);
    }

    function testSyncMultiplePools() public {
        _mockQueuedShares(POOL_A, SC_1, 100, true, 1);
        _mockQueuedAssets(POOL_A, SC_1, ASSET_1, 100, 0);
        _mockQueuedShares(POOL_B, SC_2, 200, true, 1);
        _mockQueuedAssets(POOL_B, SC_2, ASSET_1, 200, 0);

        AssetId[] memory assetIds = new AssetId[](1);
        assetIds[0] = ASSET_1;

        _expectSubmitAssets(POOL_A, SC_1, ASSET_1);
        _expectSubmitShares(POOL_A, SC_1);
        _expectSubmitAssets(POOL_B, SC_2, ASSET_1);
        _expectSubmitShares(POOL_B, SC_2);

        queueManager.sync{value: 0.1 ether}(POOL_A, SC_1, assetIds, address(this));
        (, uint64 lastSyncA,) = queueManager.scQueueState(POOL_A, SC_1);

        assertEq(lastSyncA, block.timestamp);

        queueManager.sync{value: 0.1 ether}(POOL_B, SC_2, assetIds, address(this));
        (, uint64 lastSyncB,) = queueManager.scQueueState(POOL_B, SC_2);

        assertEq(lastSyncB, block.timestamp);
    }
}
