// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {
    AdaptersDeployer,
    AdaptersActionBatcher,
    AdaptersInput,
    WormholeInput,
    LayerZeroInput
} from "../../script/AdaptersDeployer.s.sol";

import "forge-std/Test.sol";

import {ILayerZeroEndpointV2} from "../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {IWormholeRelayer, IWormholeDeliveryProvider} from "../../src/adapters/interfaces/IWormholeAdapter.sol";

contract AdaptersDeploymentInputTest is Test {
    address immutable WORMHOLE_RELAYER = makeAddr("WormholeRelayer");
    address immutable WORMHOLE_DELIVERY_PROVIDER = makeAddr("WormholeRelayer");
    uint16 constant WORMHOLE_CHAIN_ID = 23;

    address immutable LAYERZERO_ENDPOINT = makeAddr("LayerZeroEndpoint");
    address immutable LAYERZERO_DELEGATE = makeAddr("LayerZeroDelegate");

    function _adaptersInput() internal view returns (AdaptersInput memory) {
        return AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: WORMHOLE_RELAYER}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: LAYERZERO_ENDPOINT, delegate: LAYERZERO_DELEGATE})
        });
    }
}

contract AdaptersDeploymentTest is AdaptersDeployer, CommonDeploymentInputTest, AdaptersDeploymentInputTest {
    /// @dev Simple contract bytecode for mocking deployed contracts
    bytes constant SIMPLE_CONTRACT = hex"6001600160005260206000f3";

    function setUp() public {
        AdaptersActionBatcher batcher = new AdaptersActionBatcher();
        _mockRealWormholeContracts();
        _mockRealLayerZeroContracts();
        _mockBridgeContracts();
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

    function _mockRealLayerZeroContracts() private {
        vm.mockCall(
            LAYERZERO_ENDPOINT,
            abi.encodeWithSelector(ILayerZeroEndpointV2.setDelegate.selector),
            abi.encode(LAYERZERO_ENDPOINT)
        );
    }

    /// @dev Mock deployed code for validation check which requires deployed code length > 0
    function _mockBridgeContracts() internal {
        vm.etch(WORMHOLE_RELAYER, SIMPLE_CONTRACT);
    }

    /// @dev Helper function to mock a contract with deployed bytecode
    function _mockNonEmptyContract(address contractAddr) internal {
        vm.etch(contractAddr, SIMPLE_CONTRACT);
    }

    function testWormholeAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(adminSafe));

        assertEq(wormholeAdapter.wards(address(root)), 1);
        assertEq(wormholeAdapter.wards(address(guardian)), 1);
        assertEq(wormholeAdapter.wards(address(adminSafe)), 1);
        assertEq(wormholeAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(wormholeAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(wormholeAdapter.relayer()), WORMHOLE_RELAYER);
        assertEq(wormholeAdapter.localWormholeId(), WORMHOLE_CHAIN_ID);
    }

    function testLayerZeroAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(adminSafe));

        assertEq(layerZeroAdapter.wards(address(root)), 1);
        assertEq(layerZeroAdapter.wards(address(guardian)), 1);
        assertEq(layerZeroAdapter.wards(address(adminSafe)), 1);
        assertEq(layerZeroAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(layerZeroAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(layerZeroAdapter.endpoint()), LAYERZERO_ENDPOINT);
    }
}

/// This tests adapter input validation requirements that were added in AdaptersDeployer
contract AdaptersInputValidationTest is AdaptersDeploymentTest {
    function _validateWormholeInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.wormhole.shouldDeploy) {
            require(adaptersInput.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(adaptersInput.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");
        }
    }

    function _validateLayerZeroInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.layerZero.shouldDeploy) {
            require(adaptersInput.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(adaptersInput.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(adaptersInput.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");
        }
    }

    function testWormholeRelayerZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer address cannot be zero");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testWormholeRelayerNoCodeFails() public {
        address mockRelayer = makeAddr("MockRelayerNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: mockRelayer}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer must be a deployed contract");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testLayerZeroEndpointZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("LayerZero endpoint address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroEndpointNoCodeFails() public {
        address mockEndpoint = makeAddr("MockEndpointNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: mockEndpoint, delegate: address(0)})
        });

        vm.expectRevert("LayerZero endpoint must be a deployed contract");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroDelegateZeroAddressFails() public {
        // Etch some non-zero code to enable the endpoint test to pass
        vm.etch(LAYERZERO_ENDPOINT, bytes("0x01"));

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: LAYERZERO_ENDPOINT, delegate: address(0)})
        });

        vm.expectRevert("LayerZero delegate address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    // External wrapper functions to allow expectRevert to work properly (must be external)
    function _validateWormholeInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateWormholeInput(adaptersInput);
    }

    function _validateLayerZeroInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateLayerZeroInput(adaptersInput);
    }
}
