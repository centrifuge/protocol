// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {
    AdaptersDeployer,
    AdaptersActionBatcher,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput
} from "../../script/AdaptersDeployer.s.sol";

import "forge-std/Test.sol";

import {ILayerZeroEndpointV2} from "../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {IWormholeRelayer, IWormholeDeliveryProvider} from "../../src/adapters/interfaces/IWormholeAdapter.sol";

contract AdaptersDeploymentInputTest is Test {
    address immutable WORMHOLE_RELAYER = makeAddr("WormholeRelayer");
    address immutable WORMHOLE_DELIVERY_PROVIDER = makeAddr("WormholeRelayer");
    uint16 constant WORMHOLE_CHAIN_ID = 23;

    address immutable AXELAR_GATEWAY = makeAddr("AxelarGateway");
    address immutable AXELAR_GAS_SERVICE = makeAddr("AxelarGasService");

    address immutable LAYERZERO_ENDPOINT = makeAddr("LayerZeroEndpoint");
    address immutable LAYERZERO_DELEGATE = makeAddr("LayerZeroDelegate");

    function _adaptersInput() internal view returns (AdaptersInput memory) {
        return AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: WORMHOLE_RELAYER}),
            axelar: AxelarInput({shouldDeploy: true, gateway: AXELAR_GATEWAY, gasService: AXELAR_GAS_SERVICE}),
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
        vm.etch(AXELAR_GATEWAY, SIMPLE_CONTRACT);
        vm.etch(AXELAR_GAS_SERVICE, SIMPLE_CONTRACT);
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

    function testAxelarAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(guardian));
        vm.assume(nonWard != address(adminSafe));

        assertEq(axelarAdapter.wards(address(root)), 1);
        assertEq(axelarAdapter.wards(address(guardian)), 1);
        assertEq(axelarAdapter.wards(address(adminSafe)), 1);
        assertEq(axelarAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(axelarAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(axelarAdapter.axelarGateway()), AXELAR_GATEWAY);
        assertEq(address(axelarAdapter.axelarGasService()), AXELAR_GAS_SERVICE);
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

    function _validateAxelarInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.axelar.shouldDeploy) {
            require(adaptersInput.axelar.gateway != address(0), "Axelar gateway address cannot be zero");
            require(adaptersInput.axelar.gasService != address(0), "Axelar gas service address cannot be zero");
            require(adaptersInput.axelar.gateway.code.length > 0, "Axelar gateway must be a deployed contract");
            require(adaptersInput.axelar.gasService.code.length > 0, "Axelar gas service must be a deployed contract");
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
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer address cannot be zero");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testWormholeRelayerNoCodeFails() public {
        address mockRelayer = makeAddr("MockRelayerNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: mockRelayer}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer must be a deployed contract");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testAxelarGatewayZeroAddressFails() public {
        address validGasService = makeAddr("ValidGasService");
        _mockNonEmptyContract(validGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: address(0), gasService: validGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gateway address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceZeroAddressFails() public {
        address validGateway = makeAddr("ValidGateway");
        _mockNonEmptyContract(validGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: validGateway, gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gas service address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGatewayNoCodeFails() public {
        address mockGateway = makeAddr("MockGatewayNoCode");
        address mockGasService = makeAddr("MockGasService");

        // Mock code for gas service but not gateway
        _mockNonEmptyContract(mockGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gateway must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceNoCodeFails() public {
        address mockGateway = makeAddr("MockGateway");
        address mockGasService = makeAddr("MockGasServiceNoCode");

        // Mock code for gateway but not gas service
        _mockNonEmptyContract(mockGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gas service must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testLayerZeroEndpointZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("LayerZero endpoint address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroEndpointNoCodeFails() public {
        address mockEndpoint = makeAddr("MockEndpointNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
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
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: LAYERZERO_ENDPOINT, delegate: address(0)})
        });

        vm.expectRevert("LayerZero delegate address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    // External wrapper functions to allow expectRevert to work properly (must be external)
    function _validateWormholeInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateWormholeInput(adaptersInput);
    }

    function _validateAxelarInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateAxelarInput(adaptersInput);
    }

    function _validateLayerZeroInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateLayerZeroInput(adaptersInput);
    }
}
