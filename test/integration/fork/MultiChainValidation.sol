// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainConfigs} from "./ChainConfigs.sol";
import {ForkTestLiveValidation} from "./ForkTestLiveValidation.sol";

import "forge-std/Test.sol";

import {VMLabeling} from "../utils/VMLabeling.sol";

/// @title MultiChainValidation
/// @notice Contract for validating protocol deployments across multiple chains
contract MultiChainValidation is Test, VMLabeling {
    struct ForkContext {
        uint256 forkId;
        string chainName;
    }

    mapping(string => ForkContext) public forkContexts;

    function setUp() public {
        _setupVMLabels();

        ChainConfigs.ChainConfig[6] memory chainConfigs = ChainConfigs.getAllChains();

        for (uint256 i = 0; i < chainConfigs.length; i++) {
            ChainConfigs.ChainConfig memory config = chainConfigs[i];
            string memory rpcUrl = _resolveRpcUrl(config);
            uint256 forkId = vm.createFork(rpcUrl);
            forkContexts[config.name] = ForkContext({forkId: forkId, chainName: config.name});
        }
    }

    function test_validateEthereum() public {
        _validateChain("Ethereum");
    }

    function test_validateBase() public {
        _validateChain("Base");
    }

    function test_validateArbitrum() public {
        _validateChain("Arbitrum");
    }

    function test_validateAvalanche() public {
        _validateChain("Avalanche");
    }

    function test_validateBNB() public {
        _validateChain("BNB");
    }

    function test_validatePlume() public {
        _validateChain("Plume");
    }

    /// @notice Validates deployment on a specific chain
    function _validateChain(string memory chainName) internal {
        ForkContext memory context = forkContexts[chainName];
        ChainConfigs.ChainConfig memory config = ChainConfigs.getChainConfig(chainName);

        vm.selectFork(context.forkId);

        ForkTestLiveValidation validator = new ForkTestLiveValidation();
        validator._initializeContractAddresses();

        validator._configureChain(config.adminSafe, config.centrifugeId);

        validator.validateDeployment();
    }

    /// @notice Resolves RPC URL using environment variable with config fallback
    function _resolveRpcUrl(ChainConfigs.ChainConfig memory config) internal view returns (string memory) {
        try vm.envString(config.envVarName) returns (string memory envRpc) {
            if (bytes(envRpc).length > 0) {
                return envRpc;
            }
        } catch {
            // Environment variable not set or empty, use config fallback
        }
        return config.publicRpc;
    }
}
