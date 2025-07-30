// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {
    AdaptersDeployer,
    AdaptersActionBatcher,
    AdaptersInput,
    WormholeInput,
    AxelarInput
} from "../../script/AdaptersDeployer.s.sol";

import "forge-std/Test.sol";

import {IWormholeRelayer, IWormholeDeliveryProvider} from "../../src/adapters/interfaces/IWormholeAdapter.sol";

contract AdaptersDeploymentInputTest is Test {
    address immutable WORMHOLE_RELAYER = makeAddr("WormholeRelayer");
    address immutable WORMHOLE_DELIVERY_PROVIDER = makeAddr("WormholeRelayer");
    uint16 constant WORMHOLE_CHAIN_ID = 23;

    address immutable AXELAR_GATEWAY = makeAddr("AxelarGateway");
    address immutable AXELAR_GAS_SERVICE = makeAddr("AxelarGasService");

    function _adaptersInput() internal view returns (AdaptersInput memory) {
        return AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: WORMHOLE_RELAYER}),
            axelar: AxelarInput({shouldDeploy: true, gateway: AXELAR_GATEWAY, gasService: AXELAR_GAS_SERVICE})
        });
    }
}

contract AdaptersDeploymentTest is AdaptersDeployer, CommonDeploymentInputTest, AdaptersDeploymentInputTest {
    function setUp() public {
        AdaptersActionBatcher batcher = new AdaptersActionBatcher();
        _mockRealWormholeContracts();
        deployAdapters(_commonInput(), _adaptersInput(), batcher);
        removeAdaptersDeployerAccess(batcher);
    }

    function _mockRealWormholeContracts() private {
        vm.mockCall(
            WORMHOLE_RELAYER,
            abi.encodeWithSelector(IWormholeRelayer.getDefaultDeliveryProvider.selector),
            abi.encode(WORMHOLE_DELIVERY_PROVIDER)
        );

        vm.mockCall(
            WORMHOLE_DELIVERY_PROVIDER,
            abi.encodeWithSelector(IWormholeDeliveryProvider.chainId.selector),
            abi.encode(WORMHOLE_CHAIN_ID)
        );
    }

    function testWormholeAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));

        assertEq(wormholeAdapter.wards(address(root)), 1);
        assertEq(wormholeAdapter.wards(address(guardian)), 1);
        assertEq(wormholeAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(wormholeAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(wormholeAdapter.relayer()), WORMHOLE_RELAYER);
        assertEq(wormholeAdapter.localWormholeId(), WORMHOLE_CHAIN_ID);
    }

    function testAxelarAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));

        assertEq(axelarAdapter.wards(address(root)), 1);
        assertEq(axelarAdapter.wards(address(guardian)), 1);
        assertEq(axelarAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(axelarAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(axelarAdapter.axelarGateway()), AXELAR_GATEWAY);
        assertEq(address(axelarAdapter.axelarGasService()), AXELAR_GAS_SERVICE);
    }
}
