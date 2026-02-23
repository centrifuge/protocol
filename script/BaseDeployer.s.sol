// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CreateXScript} from "./utils/CreateXScript.sol";
import {CREATEX_ADDRESS} from "./utils/CreateX.d.sol";
import {ICreateX} from "./utils/ICreateX.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

function makeSalt(string memory contractName, string memory version, string memory suffix, address deployer)
    pure
    returns (bytes32)
{
    // Legacy contracts had a different salt computation (i.e: root in some chains)
    if (keccak256(abi.encodePacked(version)) == keccak256(abi.encodePacked("3"))) {
        return keccak256(abi.encodePacked(contractName, keccak256(abi.encodePacked(version))));
    }

    bytes32 versionHash =
        bytes(suffix).length > 0 ? bytes32(bytes(string.concat(version, "-", suffix))) : bytes32(bytes(version));
    bytes32 baseHash = keccak256(abi.encodePacked(contractName, versionHash));

    // NOTE: To avoid CreateX InvalidSalt issues, 21st byte needs to be 0
    return bytes32(abi.encodePacked(bytes20(deployer), bytes1(0x0), bytes11(baseHash)));
}

/// @dev Legacy salts don't embed the deployer address, so CreateX guards them with keccak256(salt).
///      New salts embed the deployer in the first 20 bytes and use keccak256(deployer || salt).
function legacyCreate3Address(bytes32 salt) pure returns (address) {
    bytes32 guardedSalt = keccak256(abi.encodePacked(salt));
    return ICreateX(CREATEX_ADDRESS).computeCreate3Address(guardedSalt, CREATEX_ADDRESS);
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
        address predicted = _isLegacyVersion(contractVersion)
            ? legacyCreate3Address(salt)
            : computeCreate3Address(salt, deployer);
        register(contractName, predicted, contractVersion);
    }

    function previewCreate3Address(string memory contractName, string memory contractVersion)
        internal
        view
        returns (address)
    {
        bytes32 salt = makeSalt(contractName, contractVersion, suffix, deployer);
        return _isLegacyVersion(contractVersion)
            ? legacyCreate3Address(salt)
            : computeCreate3Address(salt, deployer);
    }

    function _isLegacyVersion(string memory version) internal pure returns (bool) {
        return keccak256(abi.encodePacked(version)) == keccak256(abi.encodePacked("3"));
    }
}
