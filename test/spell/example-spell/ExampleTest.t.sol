// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {testContractsFromConfig} from "../validation/TestContracts.sol";
import {BaseValidator} from "../validation/BaseValidator.sol";
import {ValidationExecutor} from "../validation/ValidationExecutor.sol";
import {Validate_PreExample, Validate_CacheExample, Validate_PostExample} from "./validators/Validate_Example.sol";
import {Env} from "../../../script/utils/EnvConfig.s.sol";

contract ExampleTest {
    string chainName = "ethereum";
    BaseValidator[] pre;
    BaseValidator[] cache;
    BaseValidator[] post;

    constructor() {
        // Add pre validators:
        pre.push(new Validate_PreExample());

        // Add cache validators:
        cache.push(new Validate_CacheExample());

        // Add post validators:
        post.push(new Validate_PostExample());
    }

    function testSuite() external {
        ValidationExecutor executor = new ValidationExecutor(chainName, "example");
        executor.runPreValidation(pre, false);
        executor.runCacheValidation(cache);

        // Here goes the spell

        executor.runPostValidation(post, testContractsFromConfig(Env.load(chainName)));
        // You can also use testContractsFromConfig(fullDeployer)
    }
}
