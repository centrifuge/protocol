// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseDeployer} from "./BaseDeployer.s.sol";

import {DeployGate} from "../../src/deployment/misc/DeployGate.sol";

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {EnvConfig, Env} from "../utils/EnvConfig.s.sol";

address constant MAINNET_DEPLOYER = 0x926702C7f1af679a8f99A40af8917DDd82fD6F6c;

/// @title  DeployGateDeployer
/// @notice Brings up the DeployGate that the gated deploy scripts need, and nothing else.
///
/// @dev    The gate is the one contract that cannot be deployed through a gate, which is why this script
///         deploys it directly, through BaseDeployer, rather than through GatedDeployer. It runs once per
///         chain, and reports the gate like any other deployed contract, so that it ends up in
///         env/<network>.json, which is where the gated scripts read it from.
///
///         The sender becomes the first admin and is embedded in the salt, so nobody else can take that
///         address. Use the same sender on every chain, or protocol addresses will differ between them.
///
///         EXECUTORS is the comma-separated list of accounts the gate lets run the execute phase. They need no
///         privilege anywhere else, and none of them has to be the admin: an executor can only deploy what the
///         admin has validated. The admin changes the set afterwards through `updateExecutor`, so this is a
///         starting point rather than a commitment.
///
///         SUFFIX isolates a gate the way it isolates a deployment, and is ignored on mainnet, exactly as in
///         LaunchDeployer. It has to be the same one both scripts see: it moves the gate, everything the gate
///         deploys, and therefore the root this gate is going to be governed by.
contract DeployGateDeployer is BaseDeployer {
    function run() external {
        EnvConfig memory config = Env.load();
        vm.startBroadcast();

        startDeploymentOutput();

        require(!config.network.isMainnet() || msg.sender == MAINNET_DEPLOYER, "wrong deployer");

        _init(config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string("")));
        address[] memory executors = vm.envAddress("EXECUTORS", ",");

        // The gate is the one contract the sender deploys itself, so the sender is what its address derives
        // from. Everything else is deployed by the gate, and derives from the gate
        address gate = create3Address("deployGate", "v1", msg.sender);

        // Protocol addresses derive from the gate rather than from the sender, so this gate already determines
        // them, before anything is deployed
        address root = create3Address("root", V3_1, gate);

        // Once per chain, so a rerun is a no-op rather than a CreateX failure. Still reported, which is how
        // a chain that has its gate but not the address in its env file gets it back
        if (gate.code.length > 0) {
            console.log("DeployGate already deployed at %s, nothing to do", gate);
            register("deployGate", gate, "v1");
        } else {
            // Governance is a ward of the gate from the start, so it can name a different admin
            create3(
                "deployGate",
                "v1",
                abi.encodePacked(type(DeployGate).creationCode, abi.encode(msg.sender, root, executors))
            );
        }

        saveDeploymentOutput(config.network.name);

        vm.stopBroadcast();
    }
}
