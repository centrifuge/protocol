// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {TestContracts} from "./TestContracts.sol";
import {ValidationExecutor} from "./ValidationExecutor.sol";
import {Validate_PreExample, Validate_CacheExample, Validate_PostExample} from "./validators/Validate_Example.sol";

contract ValidationSuite {
    string network;

    constructor(string memory network_) {
        network = network_;
    }

    /// @notice Run pre-migration validation
    /// @param shouldRevert If true, reverts on errors; if false, displays warnings
    function runPreValidation(bool shouldRevert) public returns (bool) {
        TestContracts memory empty;
        ValidationExecutor executor = new ValidationExecutor(network, empty);
        executor.cleanCache();

        // Add preValidators here:
        executor.add(new Validate_PreExample());
        executor.add(new Validate_CacheExample());

        return executor.execute("PRE-MIGRATION", shouldRevert);
    }

    /// @notice Run post-migration validation (always reverts on errors)
    /// @param latest The newly deployed contracts to validate against
    function runPostValidation(TestContracts memory latest) public returns (bool) {
        ValidationExecutor executor = new ValidationExecutor(network, latest);

        // Add postValidators here:
        executor.add(new Validate_PostExample());

        return executor.execute("POST-MIGRATION", true); // Always revert on POST errors
    }
}
