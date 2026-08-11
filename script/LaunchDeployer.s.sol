// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployPhase} from "./GatedDeployer.s.sol";
import {EnvConfig, Env, prettyEnvString} from "./utils/EnvConfig.s.sol";
import {
    DeployerInput,
    FullDeployer,
    AdaptersInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    HyperlaneInput
} from "./FullDeployer.s.sol";

import {DeployGate} from "../src/deployment/misc/DeployGate.sol";

import {ISafe} from "../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

contract LaunchDeployer is FullDeployer {
    address constant PROTOCOL_SAFE = 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225;
    address constant OPS_SAFE = 0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16;

    function run() public virtual {
        // One run per phase, always, so that every deployment is committed to on chain before any of it is
        // deployed, and so that testnets and anvil rehearse exactly what mainnet does. Running them apart is
        // also the only thing that proves the two agree: the execute phase rebuilds every init code in a
        // fresh process, and has to land on exactly what the validate phase committed
        bytes32 phase = keccak256(bytes(vm.envOr("DEPLOY_PHASE", string(""))));
        bool validating = phase == keccak256("validate");
        require(validating || phase == keccak256("execute"), "DEPLOY_PHASE must be validate or execute");

        vm.startBroadcast();

        // Validating deploys nothing, so it reports nothing: the manifest belongs to the phase that deploys.
        // Opening it here and writing it below would replace the addresses of whatever was deployed last with
        // an empty set, leaving the execute phase to put them back
        if (!validating) startDeploymentOutput();

        EnvConfig memory config = Env.load(prettyEnvString("NETWORK"));

        DeployerInput memory input = DeployerInput({
            centrifugeId: config.network.centrifugeId,
            suffix: config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string("")),
            txLimits: config.network.buildBatchLimits(),
            protocolSafe: ISafe(config.network.protocolAdmin),
            opsSafe: ISafe(config.network.opsAdmin),
            adapters: AdaptersInput({
                layerZero: LayerZeroInput({
                    shouldDeploy: config.adapters.layerZero.deploy,
                    endpoint: config.adapters.layerZero.endpoint,
                    delegate: config.network.protocolAdmin,
                    configParams: config.buildLayerZeroConfigParams()
                }),
                axelar: AxelarInput({
                    shouldDeploy: config.adapters.axelar.deploy,
                    gateway: config.adapters.axelar.gateway,
                    gasService: config.adapters.axelar.gasService
                }),
                chainlink: ChainlinkInput({
                    shouldDeploy: config.adapters.chainlink.deploy, ccipRouter: config.adapters.chainlink.ccipRouter
                }),
                hyperlane: HyperlaneInput({
                    shouldDeploy: config.adapters.hyperlane.deploy,
                    mailbox: config.adapters.hyperlane.mailbox,
                    ism: config.adapters.hyperlane.ism
                }),
                connections: config.adapterConnections()
            })
        });

        // Hardcoded admins to double-check a correct mainnet deployment, on what the deployment is about to be
        // told. The guardians do not exist yet in this phase, and this is the phase where it matters: a wrong
        // env file aborts before the admin signs a commitment to contracts built around the wrong safes
        if (config.network.isMainnet() && validating) {
            require(address(input.protocolSafe) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(input.opsSafe) == OPS_SAFE, "wrong ops admin");
        }

        DeployGate gate = DeployGate(config.contracts.deployGate);

        deployFull(input, msg.sender, validating ? DeployPhase.Validate : DeployPhase.Execute, gate);

        // And the same on what the deployment produced, which the check above cannot speak for
        if (config.network.isMainnet() && !validating) {
            require(address(protocolGuardian.safe()) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(opsGuardian.opsSafe()) == OPS_SAFE, "wrong ops admin");
        }

        if (!validating) saveDeploymentOutput();

        vm.stopBroadcast();
    }
}
