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
    string internal prefix;
    address public deployer;

    function _init(string memory prefix_, address deployer_) internal {
        setUpCreateXFactory();

        prefix = prefix_;
        deployer = deployer_;
    }

    /// @dev Generates a deterministic salt and registers the predicted address.
    ///      The version must match the one used at initial deployment to reuse existing addresses.
    ///      Use the PREFIX envvar (instead of changing the version) to create isolated fresh deployments.
    function createSalt(string memory contractName, string memory contractVersion) internal returns (bytes32 salt) {
        string memory saltKey = bytes(prefix).length > 0 ? string.concat(prefix, contractName) : contractName;
        salt = makeSalt(saltKey, bytes32(bytes(contractVersion)), deployer);
        register(contractName, computeCreate3Address(salt, deployer));
    }

    function previewCreate3Address(string memory contractName, string memory contractVersion)
        internal
        view
        returns (address)
    {
        string memory saltKey = bytes(prefix).length > 0 ? string.concat(prefix, contractName) : contractName;
        return computeCreate3Address(makeSalt(saltKey, bytes32(bytes(contractVersion)), deployer), deployer);
    }
}
