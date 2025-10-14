// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../../../src/core/spoke/interfaces/IBalanceSheet.sol";

import {IMerkleProofManager} from "../../../../src/managers/spoke/interfaces/IMerkleProofManager.sol";
import {IMerkleProofManagerFactory} from "../../../../src/managers/spoke/interfaces/IMerkleProofManagerFactory.sol";
import {MerkleProofManager, MerkleProofManagerFactory} from "../../../../src/managers/spoke/MerkleProofManager.sol";

import "forge-std/Test.sol";

contract MerkleProofManagerTest is Test {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    address contractUpdater = makeAddr("contractUpdater");
    address strategist = makeAddr("strategist");
    address unauthorized = makeAddr("unauthorized");

    MerkleProofManager manager;

    function setUp() public virtual {
        manager = new MerkleProofManager(POOL_A, contractUpdater);
    }

    function testConstructor() public view {
        assertEq(manager.poolId().raw(), POOL_A.raw());
        assertEq(manager.contractUpdater(), contractUpdater);
    }

    function testReceiveEther() public {
        uint256 amount = 1 ether;

        (bool success,) = address(manager).call{value: amount}("");
        assertTrue(success);
        assertEq(address(manager).balance, amount);
    }
}

contract MerkleProofManagerTrustedCallFailureTests is MerkleProofManagerTest {
    using CastLib for *;

    function testInvalidPoolId() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IMerkleProofManager.InvalidPoolId.selector);
        vm.prank(contractUpdater);
        manager.trustedCall(POOL_B, SC_1, payload);
    }

    function testNotAuthorized() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectRevert(IMerkleProofManager.NotAuthorized.selector);
        vm.prank(unauthorized);
        manager.trustedCall(POOL_A, SC_1, payload);
    }
}

contract MerkleProofManagerTrustedCallSuccessTests is MerkleProofManagerTest {
    using CastLib for *;

    function testTrustedCallPolicySuccess() public {
        bytes32 rootHash = keccak256("root");
        bytes memory payload = abi.encode(strategist.toBytes32(), rootHash);

        vm.expectEmit();
        emit IMerkleProofManager.UpdatePolicy(strategist, bytes32(0), rootHash);

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, payload);

        assertEq(manager.policy(strategist), rootHash);
    }

    function testTrustedCallPolicyUpdate() public {
        bytes32 oldRoot = keccak256("oldRoot");
        bytes32 newRoot = keccak256("newRoot");

        // Set initial policy
        bytes memory initialPayload = abi.encode(strategist.toBytes32(), oldRoot);
        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, initialPayload);
        assertEq(manager.policy(strategist), oldRoot);

        // Update policy
        bytes memory updatePayload = abi.encode(strategist.toBytes32(), newRoot);

        vm.expectEmit();
        emit IMerkleProofManager.UpdatePolicy(strategist, oldRoot, newRoot);

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, updatePayload);
        assertEq(manager.policy(strategist), newRoot);
    }

    function testTrustedCallMultipleStrategists() public {
        address strategist1 = makeAddr("strategist1");
        address strategist2 = makeAddr("strategist2");
        bytes32 root1 = keccak256("root1");
        bytes32 root2 = keccak256("root2");

        bytes memory payload1 = abi.encode(strategist1.toBytes32(), root1);
        bytes memory payload2 = abi.encode(strategist2.toBytes32(), root2);

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, payload1);

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, payload2);

        assertEq(manager.policy(strategist1), root1);
        assertEq(manager.policy(strategist2), root2);
    }

    function testTrustedCallClearPolicy() public {
        bytes32 rootHash = keccak256("root");

        // Set initial policy
        bytes memory setPayload = abi.encode(strategist.toBytes32(), rootHash);
        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, setPayload);
        assertEq(manager.policy(strategist), rootHash);

        // Clear policy by setting to zero
        bytes memory clearPayload = abi.encode(strategist.toBytes32(), bytes32(0));

        vm.expectEmit();
        emit IMerkleProofManager.UpdatePolicy(strategist, rootHash, bytes32(0));

        vm.prank(contractUpdater);
        manager.trustedCall(POOL_A, SC_1, clearPayload);
        assertEq(manager.policy(strategist), bytes32(0));
    }
}

contract MerkleProofManagerFactoryTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);

    address contractUpdater = makeAddr("contractUpdater");
    IBalanceSheet balanceSheet;
    ISpoke spoke;
    MerkleProofManagerFactory factory;

    function setUp() public virtual {
        balanceSheet = IBalanceSheet(makeAddr("balanceSheet"));
        spoke = ISpoke(makeAddr("spoke"));

        vm.mockCall(address(balanceSheet), abi.encodeWithSelector(IBalanceSheet.spoke.selector), abi.encode(spoke));

        factory = new MerkleProofManagerFactory(contractUpdater, balanceSheet);
    }

    function testConstructor() public view {
        assertEq(factory.contractUpdater(), contractUpdater);
        assertEq(address(factory.balanceSheet()), address(balanceSheet));
    }
}

contract MerkleProofManagerFactoryNewManagerTest is MerkleProofManagerFactoryTest {
    function testNewManagerSuccess() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IMerkleProofManager manager = factory.newManager(POOL_A);
        MerkleProofManager concreteManager = MerkleProofManager(payable(address(manager)));

        assertEq(concreteManager.poolId().raw(), POOL_A.raw());
        assertEq(concreteManager.contractUpdater(), contractUpdater);
    }

    function testNewManagerInvalidPoolId() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_B), abi.encode(false));

        vm.expectRevert(IMerkleProofManagerFactory.InvalidPoolId.selector);
        factory.newManager(POOL_B);
    }

    function testNewManagerDeterministic() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        IMerkleProofManager manager1 = factory.newManager(POOL_A);

        // Second call should revert because CREATE2 with same salt fails
        vm.expectRevert();
        factory.newManager(POOL_A);

        // Verify the first manager was deployed correctly
        MerkleProofManager concreteManager = MerkleProofManager(payable(address(manager1)));
        assertEq(concreteManager.poolId().raw(), POOL_A.raw());
    }

    function testNewManagerEventEmission() public {
        vm.mockCall(address(spoke), abi.encodeWithSelector(ISpoke.isPoolActive.selector, POOL_A), abi.encode(true));

        vm.recordLogs();
        IMerkleProofManager manager = factory.newManager(POOL_A);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("DeployMerkleProofManager(uint64,address)"));
        assertEq(uint256(logs[0].topics[1]), POOL_A.raw());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(manager));
    }
}
