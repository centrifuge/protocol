// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {ERC6909NFT} from "src/misc/ERC6909NFT.sol";
import {previewAddress as _previewAddress} from "src/misc/utils/Deployment.sol";
import {IERC6909Factory} from "src/misc/interfaces/IERC6909.sol";

contract ERC6909Factory is IERC6909Factory {
    /// @inheritdoc IERC6909Factory
    function deploy(address owner, bytes32 salt) public returns (address instance) {
        instance = address(new ERC6909NFT{salt: salt}(owner));
        emit NewTokenDeployment(owner, instance);
    }

    /// @inheritdoc IERC6909Factory
    function previewAddress(address _owner, bytes32 salt) external view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(ERC6909NFT).creationCode, abi.encode(_owner));

        return _previewAddress(address(this), salt, bytecode);
    }
}
