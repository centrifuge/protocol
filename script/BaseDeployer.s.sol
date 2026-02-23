// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "./utils/CreateXScript.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

function makeSalt(string memory contractName, string memory version, string memory suffix, address deployer)
    pure
    returns (bytes32)
{
    bytes32 versionHash = bytes(suffix).length > 0
        ? bytes32(bytes(string.concat(version, "-", suffix)))
        : bytes32(bytes(version));
    bytes32 baseHash = keccak256(abi.encodePacked(contractName, versionHash));

    // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
    return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x0), bytes11(baseHash)));
}

contract BaseDeployer is Script, JsonRegistry, CreateXScript {
    string internal suffix;
    address public deployer;

    function _init(string memory suffix_, address deployer_) internal {
        setUpCreateXFactory();

        suffix = suffix_;
        deployer = deployer_;
    }

    /// @dev Generates a deterministic salt and registers the predicted address.
    ///      The version must match the one used at initial deployment to reuse existing addresses.
    ///      Use the SUFFIX envvar (instead of changing the version) to create isolated fresh deployments.
    function createSalt(string memory contractName, string memory contractVersion) internal returns (bytes32 salt) {
        salt = makeSalt(contractName, contractVersion, suffix, deployer);
        register(contractName, computeCreate3Address(salt, deployer), contractVersion);
    }

    function previewCreate3Address(string memory contractName, string memory contractVersion)
        internal
        view
        returns (address)
    {
        return computeCreate3Address(makeSalt(contractName, contractVersion, suffix, deployer), deployer);
    }
}
