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

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import "forge-std/Script.sol";

import {REPLACE} from "../utils/JsonRegistry.s.sol";
import {PROTOCOL_SAFE, OPS_SAFE} from "../utils/Admin.s.sol";
import {ChainConfig, Chains} from "../utils/ChainConfig.s.sol";

/// @notice Launches the protocol through the DeployGate, one run per phase:
///
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'validate()' --rpc-url <network> --broadcast
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'execute()'  --rpc-url <network> --broadcast
///
///         The network comes from the chain the RPC points at, and off mainnet the signer comes from the
///         PRIVATE_KEY in .env; on mainnet the admin signs validate with `--ledger --sender <addr> --slow`
///         and an executor signs execute with `--account <name> --sender <addr> --slow`. The execute phase
///         records what it deployed into env/<environment>/<network>.json itself.
contract LaunchDeployer is FullDeployer {
    /// @notice Commits the whole deployment to the gate: the single transaction the admin signs.
    function validate() public {
        _launch(DeployPhase.Validate);
    }

    /// @notice Drops the commitment without deploying any of it, leaving the namespace as it was before
    ///         `validate()`. Signed by the same account that would validate, since revoking is committing
    ///         nothing. What a commitment already deployed stays deployed: this is not a rollback
    function revoke() public {
        ChainConfig memory config = Chains.load();
        address validator_ = _validator(config);

        // A Safe validator is proposed to instead, and a proposing run broadcasts nothing
        bool broadcasting = !proposes(validator_);
        if (broadcasting) vm.startBroadcast();

        // The suffix only shapes salts, and revoking commits none
        _initGated("", msg.sender, DeployPhase.Validate, validator_, new address[](0));
        _revokeCommitment();

        if (broadcasting) vm.stopBroadcast();
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

    /// @dev A validator can never be replaced, so on mainnet it is the Safe rather than a key, and it
    ///      delegates to whichever one signs the phase. Off mainnet, the signer keeps to its own addresses
    function _validator(ChainConfig memory config) internal view returns (address) {
        return config.network.isMainnet() ? PROTOCOL_SAFE : vm.envOr("VALIDATOR", msg.sender);
    }

    function _launch(DeployPhase phase) internal {
        bool validating = phase == DeployPhase.Validate;

        ChainConfig memory config = Chains.load();
        // Only validating is the validator's own call; executing is signed by an executor key either way
        bool broadcasting = !validating || !proposes(_validator(config));

        if (broadcasting) vm.startBroadcast();

        // Validating deploys nothing, so it reports nothing: the manifest belongs to the phase that deploys.
        // Opening it here and writing it below would replace the addresses of whatever was deployed last with
        // an empty set, leaving the execute phase to put them back
        if (!validating) startDeploymentOutput(REPLACE);

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

        // Hardcoded admins to double-check a correct mainnet deployment
        if (config.network.isMainnet() && validating) {
            require(address(input.protocolSafe) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(input.opsSafe) == OPS_SAFE, "wrong ops admin");
        }

        address[] memory executors;
        if (validating) {
            executors = vm.envAddress("EXECUTORS", ",");
            require(executors.length > 0, "EXECUTORS must name at least one account");
        }

        deployFull(input, msg.sender, phase, _validator(config), executors);

        // And the same on what the deployment produced, which the check above cannot speak for
        if (config.network.isMainnet() && !validating) {
            require(address(protocolGuardian.safe()) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(opsGuardian.opsSafe()) == OPS_SAFE, "wrong ops admin");
        }

        if (!validating) saveDeploymentOutput(Chains.pathOf(config.network.name));

        if (broadcasting) vm.stopBroadcast();
    }
}
