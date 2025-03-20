// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ISafe} from "src/common/interfaces/IGuardian.sol";

import {PoolId} from "src/pools/types/PoolId.sol";

import {PoolRouter} from "src/pools/PoolRouter.sol";

import {VaultRouter} from "src/vaults/VaultRouter.sol";

import {FullDeployer} from "script/FullDeployer.s.sol";

import {LocalAdapter} from "test/integration/adapters/LocalAdapter.sol";

/// End to end testing assuming two full deployments in two different chains
contract TestEndToEnd is Test {
    ISafe immutable safeAdminA = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable safeAdminB = ISafe(makeAddr("SafeAdminB"));

    uint32 constant CHAIN_A = 5;
    uint32 constant CHAIN_B = 6;
    uint64 constant GAS = 100 wei;

    address immutable FM = makeAddr("FM");

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    /*
    function deployChain(address safeAdmin, FullDeployer deploy) public {
        deploy.deployFull(safeAdmin);

        LocalAdapter adapterA = new LocalAdapter(deploy.gateway(), address(deploy));
        deploy.wire(adapterA);

        // Configure as deployer of chain A
        vm.startPrank(address(deploy));
        adapterA.file("gateway", adapterB);
        deploy.gasService().file("messageGasLimit", GAS);
        vm.stopPrank();
    }
    */

    function setUp() public {
        deployA.deployFull(safeAdminA);
        deployB.deployFull(safeAdminB);

        // We connect both deploys through the adapters
        LocalAdapter adapterA = new LocalAdapter(deployA.gateway(), address(deployA));
        deployA.wire(adapterA);
        LocalAdapter adapterB = new LocalAdapter(deployB.gateway(), address(deployB));
        deployB.wire(adapterB);

        // Configure as deployer of chain A
        vm.startPrank(address(deployA));
        adapterA.setEndpoint(adapterB);
        deployA.gasService().file("messageGasLimit", GAS);
        vm.stopPrank();

        // Configure as deployer of chain B
        vm.startPrank(address(deployB));
        adapterB.setEndpoint(adapterA);
        deployB.gasService().file("messageGasLimit", GAS);
        vm.stopPrank();

        deployA.removeFullDeployerAccess();
        deployB.removeFullDeployerAccess();

        // Initialize accounts
        vm.deal(FM, 1 ether);

        // ChainId should never be used, instead the configured chainId
        vm.chainId(0xDEAD);
    }

    function _getRouters(bool sameChain) public returns (PoolRouter cp, VaultRouter cv) {
        cp = deployA.poolRouter();
        vm.label(address(cp), "CP");

        cv = (sameChain) ? deployA.vaultRouter() : deployB.vaultRouter();
        vm.label(address(cv), "CV");
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        (PoolRouter cp, VaultRouter cv) = _getRouters(sameChain);

        vm.prank(FM);
        PoolId poolId = cp.createPool(FM, deployA.USD(), deployA.multiShareClass());

        (bytes[] memory c, uint256 i) = (new bytes[](1), 0);
        c[i++] = abi.encodeWithSelector(PoolRouter.notifyPool.selector, CHAIN_B);
        assertEq(i, c.length);

        vm.prank(FM);
        cp.execute{value: GAS}(poolId, c);
    }
}
