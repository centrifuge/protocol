// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Validate_Vaults} from "./validators/Validate_Vaults.sol";
import {Validate_Endorsements} from "./validators/Validate_Endorsements.sol";
import {Validate_ContractWards} from "./validators/Validate_ContractWards.sol";
import {Validate_RootPermissions} from "./validators/Validate_RootPermissions.sol";
import {Validate_FileConfigurations} from "./validators/Validate_FileConfigurations.sol";
import {Validate_AdapterConfigurations} from "./validators/Validate_AdapterConfigurations.sol";

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

import {BaseValidator} from "../spell/utils/validation/BaseValidator.sol";
import {ValidationExecutor} from "../spell/utils/validation/ValidationExecutor.sol";

/// @title  LiveValidationForkTest
/// @notice Fork test that validates the complete deployment state across all mainnet networks
///         using the v2 validator paradigm with indexer data. Replaces ForkTestLiveValidation.sol.
contract LiveValidationForkTest is Test {
    function _testCase(string memory networkName) internal {
        EnvConfig memory config = Env.load(networkName);
        vm.createSelectFork(config.network.rpcUrl());

        BaseValidator[] memory validators = new BaseValidator[](6);
        validators[0] = new Validate_RootPermissions();
        validators[1] = new Validate_ContractWards();
        validators[2] = new Validate_FileConfigurations();
        validators[3] = new Validate_Endorsements();
        validators[4] = new Validate_AdapterConfigurations();
        validators[5] = new Validate_Vaults();

        ValidationExecutor executor = new ValidationExecutor(networkName, "live-validation");
        executor.runPreValidation(validators, true);
    }

    function testLiveValidation_Ethereum() external {
        _testCase("ethereum");
    }

    function testLiveValidation_Base() external {
        _testCase("base");
    }

    function testLiveValidation_Arbitrum() external {
        _testCase("arbitrum");
    }

    function testLiveValidation_Plume() external {
        _testCase("plume");
    }

    function testLiveValidation_Avalanche() external {
        _testCase("avalanche");
    }

    function testLiveValidation_BnbSmartChain() external {
        _testCase("bnb-smart-chain");
    }

    function testLiveValidation_Optimism() external {
        _testCase("optimism");
    }

    function testLiveValidation_HyperEvm() external {
        _testCase("hyper-evm");
    }

    function testLiveValidation_Monad() external {
        _testCase("monad");
    }
}
