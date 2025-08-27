// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {IBalanceSheet} from "../../../src/spoke/BalanceSheet.sol";

import {QueueManager, IQueueManager} from "../../../src/managers/QueueManager.sol";

import "forge-std/Test.sol";

contract QueueManagerTest is Test {
    using CastLib for *;

    address contractUpdater = makeAddr("ContractUpdater");
    IBalanceSheet balanceSheet = IBalanceSheet(makeAddr("BalanceSheet"));

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable SENDER = makeAddr("SENDER");
    address immutable FROM = makeAddr("FROM");
    address immutable TO = makeAddr("TO");
    address immutable MANAGER = makeAddr("MANAGER");

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));

    QueueManager queueManager = new QueueManager(contractUpdater, balanceSheet);

    function setUp() public {}
}

contract QueueManagerTestUpdateContract is QueueManagerTest {
    function testErrNotContractUpdater() public {
        vm.prank(ANY);
        vm.expectRevert(IQueueManager.NotContractUpdater.selector);
        queueManager.update(POOL_A, SC_1, bytes(""));
    }

    // TODO: happy path
}
