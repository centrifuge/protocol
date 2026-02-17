// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// NOTE: this file is added as an example and can be removed at any time.

import {testContractsFromConfig} from "./validation/TestContracts.sol";
import {ValidationSuite} from "./validation/ValidationSuite.sol";
import {Env} from "../../script/utils/EnvConfig.s.sol";

contract ValidationSuiteTest {
    string chainName = "ethereum";
    ValidationSuite suite = new ValidationSuite(chainName);

    function testSuite() external {
        suite.runPreValidation(false);
        suite.runPostValidation(testContractsFromConfig(Env.load(chainName)));
    }
}
