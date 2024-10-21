// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {ERC6909Collateral} from "src/ERC6909Collateral.sol";

contract ERC6909Factory is Auth {
    constructor(address _owner) Auth(_owner) {}

    function newCollateral(address owner, bytes32 salt) public returns (address collateral) {
        collateral = address(new ERC6909Collateral{salt: salt}(owner));
    }
}
