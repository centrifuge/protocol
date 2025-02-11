// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ICallEscrow} from "src/interfaces/ICallEscrow.sol";
import {Auth} from "src/Auth.sol";

contract CallEscrow is Auth, ICallEscrow {
    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc ICallEscrow
    function call(address target, bytes calldata data) external returns (bool success, bytes memory results) {
        return target.call(data);
    }
}
