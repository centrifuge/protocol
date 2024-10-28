// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {ERC6909Centrifuge} from "src/ERC6909/ERC6909Centrifuge.sol";
import {previewAddress as _previewAddress} from "src/utils/Deployment.sol";
import {IERC6909Factory} from "src/interfaces/ERC6909/IERC6909Factory.sol";

contract ERC6909Factory is IERC6909Factory, Auth {
    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909Factory
    function deploy(address owner, bytes32 salt) public auth returns (address collateral) {
        collateral = address(new ERC6909Centrifuge{salt: salt}(owner));
    }

    /// @inheritdoc IERC6909Factory
    function previewAddress(address _owner, bytes32 salt) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(ERC6909Centrifuge).creationCode, abi.encode(_owner));

        return _previewAddress(address(this), salt, bytecode);
    }
}
