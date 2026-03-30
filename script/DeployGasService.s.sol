// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Env, EnvConfig} from "./utils/EnvConfig.s.sol";
import {JsonRegistry} from "./utils/JsonRegistry.s.sol";

import {GasService} from "../src/admin/GasService.sol";
import {IGasService} from "../src/admin/interfaces/IGasService.sol";
import {IOpsGuardian} from "../src/admin/interfaces/IOpsGuardian.sol";

import "forge-std/Script.sol";

import {Safe, Enum} from "safe-utils/Safe.sol";

/// @title DeployGasService
/// @notice Deploys a new GasService and proposes an OpsGuardian.setGasService call via the ops Safe.
/// @dev Set NETWORK env var to the network name (e.g., "ethereum", "base", "arbitrum").
///
///      Example usage:
///        NETWORK=ethereum forge script script/DeployGasService.s.sol --rpc-url $ETH_RPC_URL --broadcast
contract DeployGasService is Script, JsonRegistry {
    using Safe for *;

    string constant LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";
    Safe.Client safe;

    function run() external {
        startDeploymentOutput();
        vm.startBroadcast();

        string memory network = vm.envString("NETWORK");
        EnvConfig memory config = Env.load(network);

        GasService gasService = new GasService(config.network.buildBatchLimits());

        string memory json = vm.readFile(string.concat("env/", network, ".json"));
        string memory currentVersion = vm.parseJsonString(json, ".contracts.gasService.version");
        register("gasService", address(gasService), _nextVersion(currentVersion));

        address opsGuardian = config.contracts.opsGuardian;
        bytes memory data = abi.encodeCall(IOpsGuardian.setGasService, (IGasService(address(gasService))));

        safe.initialize(config.network.opsAdmin);
        bytes memory signature = safe.sign(opsGuardian, data, Enum.Operation.Call, msg.sender, LEDGER_DERIVATION_PATH);
        safe.proposeTransactionWithSignature(opsGuardian, data, msg.sender, signature);

        vm.stopBroadcast();
        saveDeploymentOutput();
    }

    /// @dev Increments the path number. i.e:
    /// if v3.1   then v3.1.1
    /// if v3.1.5 then v3.1.6
    function _nextVersion(string memory current) private pure returns (string memory) {
        // Normalize: if only one dot (e.g. "v3.1"), treat as "v3.1.0" before incrementing
        bytes memory b = bytes(current);
        uint256 dotCount = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") dotCount++;
        }
        if (dotCount < 2) current = string.concat(current, ".0");

        // Find the last dot and parse the patch number after it
        b = bytes(current);
        uint256 lastDot = 0;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ".") lastDot = i;
        }

        uint256 patch = 0;
        for (uint256 i = lastDot + 1; i < b.length; i++) {
            patch = patch * 10 + (uint8(b[i]) - 48);
        }

        bytes memory prefix = new bytes(lastDot + 1);
        for (uint256 i = 0; i <= lastDot; i++) {
            prefix[i] = b[i];
        }

        return string.concat(string(prefix), vm.toString(patch + 1));
    }
}
