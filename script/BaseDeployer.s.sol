// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "./utils/CreateXScript.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

function makeSalt(string memory contractName, bytes32 version, address deployer) pure returns (bytes32) {
    bytes32 baseHash = keccak256(abi.encodePacked(contractName, version));

    // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
    return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x0), bytes11(baseHash)));
}

contract BaseDeployer is Script, JsonRegistry, CreateXScript {
    bytes32 public version;
    address public deployer;

    function _init(bytes32 version_, address deployer_) internal {
        // NOTE: This implementation must be idempotent
        setUpCreateXFactory();

        version = version_;
        deployer = deployer_;
    }

    /// @dev Generates a deterministic salt and registers the predicted address
    function createSalt(string memory contractName) internal returns (bytes32 salt) {
        salt = makeSalt(contractName, version, deployer);
        register(contractName, computeCreate3Address(salt, deployer));
    }

    function previewCreate3Address(string memory contractName) internal returns (address) {
        return computeCreate3Address(makeSalt(contractName, version, deployer), deployer);
    }
}
