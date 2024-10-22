// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {ERC6909Collateral} from "src/ERC6909/ERC6909Collateral.sol";
import {Deterministic} from "src/Deterministic.sol";

contract ERC6909Factory is Auth, Deterministic {
    constructor(address _owner) Auth(_owner) {}

    function deploy(address owner, bytes32 salt) public auth returns (address collateral) {
        collateral = address(new ERC6909Collateral{salt: salt}(owner));
    }

    function previewAddress(address _owner, bytes32 salt) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(ERC6909Collateral).creationCode, abi.encode(_owner));

        return _previewAddress(address(this), salt, bytecode);
    }
}
