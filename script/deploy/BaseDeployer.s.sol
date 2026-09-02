// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {JsonRegistry} from "../utils/JsonRegistry.s.sol";
import {CreateXScript} from "../utils/createx/CreateXScript.sol";

/// @dev What kind of account a run is signed as, which decides how it is signed: a key signs a forge
///      broadcast, a Safe cannot and is proposed to instead. A contract is taken to be a Safe, there being
///      nothing else a sender could be here. Code starting 0xef is the one exception: EIP-3541 keeps it
///      undeployable, so it can only be an EIP-7702 delegation, behind which a key still signs
library AccountLib {
    function isSafeAccount(address account) internal view returns (bool) {
        bytes memory code = account.code;
        return code.length > 0 && code[0] != 0xef;
    }
}

contract BaseDeployer is Script, JsonRegistry, CreateXScript {
    /// @dev Every version the deployment maintains, since a version is part of the salt and therefore of the
    ///      address. A contract keeps the version it was first deployed at, so that a release which does not
    ///      touch it leaves its address alone — which is why a release adds a constant here rather than
    ///      editing one. Nothing carries v3.1 or v3.2 any more: deploying through the gate derives every
    ///      address from it, so this release lands the whole protocol on new addresses whatever the tags
    ///      said, and keeping the old ones would claim a continuity that is gone.
    ///
    ///      `V_LATEST` is for the ones meant to move with every release, which is the action batchers:
    ///      everything else names a version explicitly, so that bumping the release cannot move an address
    ///      on its own.
    string internal constant V3_3 = "v3.3";
    string internal constant V_LATEST = V3_3;

    string internal deploymentId;
    bool private initialized;

    function _init(string memory deploymentId_) internal {
        setUpCreateXFactory();

        deploymentId = deploymentId_;
        initialized = true;
    }

    /// @dev What the deployment id turns a version into. The id is what isolates a deployment from the one that
    ///      shares its version, so it belongs to every salt the deployment builds, gated or not.
    function _versionHash(string memory version) internal view returns (bytes32) {
        require(initialized, "BaseDeployer::_init() must be called!");

        bytes memory compoundedVersion = bytes(string.concat(version, "-", deploymentId));
        require(compoundedVersion.length <= 32, "Version + deploymentId is too large");

        return bytes(deploymentId).length > 0 ? bytes32(compoundedVersion) : bytes32(bytes(version));
    }

    /// @dev The salt `deployer_` has to pass to CreateX to deploy the contract at its deterministic address.
    ///      It embeds the deployer, which is what a permissioned CreateX salt is, so asking for someone
    ///      else's is how the addresses a contract is going to deploy are known before that contract exists.
    ///      Gated deployments do not come through here: the gate builds its own CreateX salt.
    function _makeSalt(string memory contractName, string memory version, address deployer_)
        internal
        view
        returns (bytes32)
    {
        require(deployer_ != address(0), "A deployer is required to build a salt");

        bytes32 baseHash = keccak256(abi.encodePacked(contractName, _versionHash(version)));

        // Byte 20 is CreateX's cross-chain redeploy protection flag, left off so that the address stays
        // equal across chains: setting it would fold the chain id in
        return bytes32(abi.encodePacked(bytes20(deployer_), bytes1(0x0), bytes11(baseHash)));
    }

    /// @dev Salt for a contract the deployment does not report, labeled so that it is named in traces.
    ///      The version must match the one used at initial deployment to reuse existing addresses.
    ///      Use the deployment id (instead of changing the version) to create isolated fresh deployments.
    function unreportedSalt(string memory contractName, string memory contractVersion, address deployer_)
        internal
        returns (bytes32 salt)
    {
        salt = _makeSalt(contractName, contractVersion, deployer_);

        vm.label(
            computeCreate3Address(salt, deployer_), string.concat(contractName, "-", contractVersion, "-", deploymentId)
        );
    }

    /// @dev Same, for a contract the deployment reports, which is what puts it in the deployment manifest and,
    ///      from there, in `env/<environment>/<network>.json`. Deploy-time only contracts take `unreportedSalt` instead.
    function reportedSalt(string memory contractName, string memory contractVersion, address deployer_)
        internal
        returns (bytes32 salt)
    {
        salt = unreportedSalt(contractName, contractVersion, deployer_);

        register(contractName, computeCreate3Address(salt, deployer_), contractVersion);
    }

    /// @dev Deploys the contract at its deterministic address and reports it, so that a caller never handles
    ///      a salt: the sender is the deployer, which is what a directly deployed address derives from. Pass
    ///      a salt only to deploy on behalf of someone else, which in practice means a test.
    ///      Gated deployments take `submit` instead, and override this to say so.
    function create3(string memory contractName, string memory contractVersion, bytes memory initCode)
        internal
        virtual
        returns (address)
    {
        return create3(reportedSalt(contractName, contractVersion, msg.sender), initCode);
    }

    /// @dev The address `deployer_` is going to deploy the contract to, without reporting or deploying
    ///      anything. Asking for someone else's is how the addresses a contract will deploy are known before
    ///      that contract exists, which is what lets constructors be wired to dependencies not yet deployed.
    function create3Address(string memory contractName, string memory contractVersion, address deployer_)
        internal
        returns (address)
    {
        return computeCreate3Address(unreportedSalt(contractName, contractVersion, deployer_), deployer_);
    }
}
