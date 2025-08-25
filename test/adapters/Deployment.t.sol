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
    /// @dev Simple contract bytecode for mocking deployed contracts
    bytes constant SIMPLE_CONTRACT = hex"6001600160005260206000f3";

    function setUp() public {
        AdaptersActionBatcher batcher = new AdaptersActionBatcher();
        _mockRealWormholeContracts();
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

    function testWormholeRelayerZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)})
        });

        vm.expectRevert("Wormhole relayer address cannot be zero");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testWormholeRelayerNoCodeFails() public {
        address mockRelayer = makeAddr("MockRelayerNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: mockRelayer}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)})
        });

        vm.expectRevert("Wormhole relayer must be a deployed contract");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testAxelarGatewayZeroAddressFails() public {
        address validGasService = makeAddr("ValidGasService");
        _mockNonEmptyContract(validGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: address(0), gasService: validGasService})
        });

        vm.expectRevert("Axelar gateway address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceZeroAddressFails() public {
        address validGateway = makeAddr("ValidGateway");
        _mockNonEmptyContract(validGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: validGateway, gasService: address(0)})
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
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService})
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
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService})
        });

        vm.expectRevert("Axelar gas service must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    // External wrapper functions to allow expectRevert to work properly (must be external)
    function _validateWormholeInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateWormholeInput(adaptersInput);
    }

    function _validateAxelarInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateAxelarInput(adaptersInput);
    }
}
