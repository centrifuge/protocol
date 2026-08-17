// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {DeployPhase} from "./GatedDeployer.s.sol";
import {
    DeployerInput,
    FullDeployer,
    AdaptersInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    HyperlaneInput
} from "./FullDeployer.s.sol";

import {DeployGate} from "../../src/deployment/misc/DeployGate.sol";

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

import {EnvConfig, Env} from "../utils/EnvConfig.s.sol";

/// @notice Launches the protocol through the DeployGate, one run per phase:
///
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url <network> --broadcast
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url <network> --broadcast
///
///         The network comes from the chain the RPC points at, and off mainnet the signer comes from the
///         PRIVATE_KEY in .env; on mainnet the admin signs validate with `--ledger --sender <addr> --slow`
///         and an executor signs execute with `--account <name> --sender <addr> --slow`. The execute phase
///         records what it deployed into env/<network>.json itself.
contract LaunchDeployer is FullDeployer {
    address constant PROTOCOL_SAFE = 0x9711730060C73Ee7Fcfe1890e8A0993858a7D225;
    address constant OPS_SAFE = 0xd21413291444C5c104F1b5918cA0D2f6EC91Ad16;

    /// @notice Commits the whole deployment to the gate: the single transaction the admin signs.
    function validate() public {
        _launch(DeployPhase.Validate);
    }

    /// @notice Deploys what has been committed, one transaction per contract, signed by an executor.
    ///         If it stops partway, resume it — never re-run either phase from scratch over a partial
    ///         deployment (see script/deploy/README.md).
    function execute() public {
        _launch(DeployPhase.Execute);
    }

    /// @dev One run per phase, always, so that every deployment is committed to on chain before any of it
    ///      is deployed, and so that testnets and anvil rehearse exactly what mainnet does. Running them
    ///      apart is also the only thing that proves the two agree: the execute phase rebuilds every init
    ///      code in a fresh process, and has to land on exactly what the validate phase committed.
    function run() public virtual {
        revert(
            "A gated deployment is two separate runs. Pass --sig 'validate()' to commit it, "
            "then --sig 'execute()' to deploy it"
        );
    }

    function _launch(DeployPhase phase) internal {
        bool validating = phase == DeployPhase.Validate;

        EnvConfig memory config = Env.load();
        vm.startBroadcast();

        // Validating deploys nothing, so it reports nothing: the manifest belongs to the phase that deploys.
        // Opening it here and writing it below would replace the addresses of whatever was deployed last with
        // an empty set, leaving the execute phase to put them back
        if (!validating) startDeploymentOutput();

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

        deployFull(input, msg.sender, phase, gate);

        // And the same on what the deployment produced, which the check above cannot speak for
        if (config.network.isMainnet() && !validating) {
            require(address(protocolGuardian.safe()) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(opsGuardian.opsSafe()) == OPS_SAFE, "wrong ops admin");
        }

        if (!validating) saveDeploymentOutput(config.network.name);

        vm.stopBroadcast();
    }
}
