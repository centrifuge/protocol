// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {ISharedDependency} from "src/misc/interfaces/ISharedDependency.sol";

contract SharedDependency is Auth, ISharedDependency {
    address public dependency;

    constructor(address dependency_, address deployer) Auth(deployer) {
        dependency = dependency_;
    }

    function file(address dependency_) external {
        dependency = dependency_;
        emit File(dependency_);
    }
}
