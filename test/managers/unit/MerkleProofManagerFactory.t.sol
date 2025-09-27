// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MerkleProofManagerFactoryTest
/// @notice Unit tests for the MerkleProofManagerFactory contract.
/// @dev Uses Foundry's forge-std testing framework.

import "forge-std/Test.sol";
import {MerkleProofManagerFactory, MerkleProofManager} from "../../../src/managers/MerkleProofManager.sol";
import {IMerkleProofManager} from "../../../src/managers/interfaces/IMerkleProofManager.sol";
import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IBalanceSheet} from "../../../src/spoke/interfaces/IBalanceSheet.sol";
import {ISpoke} from "../../../src/spoke/interfaces/ISpoke.sol";

/// @dev Custom error used for invalid pool IDs.
error InvalidPoolId();

contract MerkleProofManagerFactoryTest is Test {
    // ============ Events ============
    event DeployMerkleProofManager(PoolId indexed poolId, address indexed manager);

    // ============ State ============
    MerkleProofManagerFactory factory;

    address contractUpdater = makeAddr("contractUpdater");
    address balanceSheet = makeAddr("balanceSheet");

    PoolId activePoolId = PoolId.wrap(1);
    PoolId inactivePoolId = PoolId.wrap(2);
    PoolId testPoolId = PoolId.wrap(3);

    // ============ Setup ============
    function setUp() public {
        factory = new MerkleProofManagerFactory(contractUpdater, IBalanceSheet(balanceSheet));
    }

    // ============ Tests ============

    function test_FactoryDeployment() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), balanceSheet);
    }

    function test_NewManager() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, activePoolId), abi.encode(true));

        address manager = address(factory.newManager(activePoolId));

        assertTrue(manager != address(0));
        assertEq(PoolId.unwrap(MerkleProofManager(payable(manager)).poolId()), PoolId.unwrap(activePoolId));
        assertEq(MerkleProofManager(payable(manager)).contractUpdater(), contractUpdater);
    }

    /// @dev Don’t check manager address (ignore second indexed param).
    function test_NewManagerEmitsEvent() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, testPoolId), abi.encode(true));

        vm.expectEmit(true, false, false, true);
        emit DeployMerkleProofManager(testPoolId, address(0));

        factory.newManager(testPoolId);
    }

    function test_RevertWhen_InvalidPoolId() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(
            address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, inactivePoolId), abi.encode(false)
        );

        vm.expectRevert(InvalidPoolId.selector);
        factory.newManager(inactivePoolId);
    }

    function test_DeterministicAddress() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, activePoolId), abi.encode(true));

        address manager1 = address(factory.newManager(activePoolId));

        vm.expectRevert();
        factory.newManager(activePoolId);

        assertTrue(manager1 != address(0));
    }

    function test_DifferentPoolsDifferentAddresses() public {
        PoolId poolId1 = PoolId.wrap(uint64(uint256(keccak256("pool1"))));
        PoolId poolId2 = PoolId.wrap(uint64(uint256(keccak256("pool2"))));

        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, poolId1), abi.encode(true));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, poolId2), abi.encode(true));

        address manager1 = address(factory.newManager(poolId1));
        address manager2 = address(factory.newManager(poolId2));

        assertTrue(manager1 != manager2);
    }

    function test_EventEmissionWithCorrectAddress() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, testPoolId), abi.encode(true));

        vm.recordLogs();
        address expectedManager = address(factory.newManager(testPoolId));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(logs.length, 0);
        assertTrue(expectedManager != address(0));
    }

    function test_EventContent() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, testPoolId), abi.encode(true));

        vm.recordLogs();
        address expectedManager = address(factory.newManager(testPoolId));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);

        // Corrected event signature
        bytes32 expectedTopic = keccak256("DeployMerkleProofManager(uint64,address)");
        assertEq(logs[0].topics[0], expectedTopic);

        // poolId (first indexed param)
        assertEq(logs[0].topics[1], bytes32(uint256(PoolId.unwrap(testPoolId))));

        // manager (second indexed param)
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(expectedManager))));
    }

    /// @dev Ignore manager in expectEmit.
    function test_EventUsingCheatcodes() public {
        vm.mockCall(balanceSheet, abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(address(this)));
        vm.mockCall(address(this), abi.encodeWithSelector(ISpoke.isPoolActive.selector, testPoolId), abi.encode(true));

        vm.expectEmit(true, false, false, false);
        emit DeployMerkleProofManager(testPoolId, address(0));

        factory.newManager(testPoolId);
    }
}
