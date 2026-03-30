// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Env, EnvConfig} from "./utils/EnvConfig.s.sol";

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
contract DeployGasService is Script {
    using Safe for *;

    string constant LEDGER_DERIVATION_PATH = "m/44'/60'/0'/0/0";
    Safe.Client safe;

    function run() external {
        vm.startBroadcast();

        EnvConfig memory config = Env.load(vm.envString("NETWORK"));

        GasService gasService = new GasService(config.network.buildBatchLimits());
        console.log("GasService deployed at:", address(gasService));

        address opsGuardian = config.contracts.opsGuardian;
        bytes memory data = abi.encodeCall(IOpsGuardian.setGasService, (IGasService(address(gasService))));

        safe.initialize(config.network.opsAdmin);
        bytes memory signature = safe.sign(opsGuardian, data, Enum.Operation.Call, msg.sender, LEDGER_DERIVATION_PATH);
        safe.proposeTransactionWithSignature(opsGuardian, data, msg.sender, signature);

        vm.stopBroadcast();
    }
}
