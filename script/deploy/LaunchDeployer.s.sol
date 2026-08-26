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
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'commit()' --rpc-url <network> --broadcast
///         forge script script/deploy/LaunchDeployer.s.sol --sig 'deploy()'  --rpc-url <network> --broadcast
///
///         The network comes from the chain the RPC points at, and off mainnet the signer comes from the
///         PRIVATE_KEY in .env; on mainnet the admin signs the commit with `--ledger --sender <addr> --slow`
///         and an executor signs the deploy with `--account <name> --sender <addr> --slow`. The deploy phase
///         records what it deployed into env/<environment>/<network>.json itself.
contract LaunchDeployer is FullDeployer {
    uint256 public constant MAINNET_DELAY = 48 hours;

    /// @notice Commits the whole deployment to the gate: the single transaction the admin signs.
    function commit() public {
        _launch(DeployPhase.Commit);
    }

    /// @notice Drops the commitment without deploying any of it, leaving the namespace as it was before
    ///         `commit()`. Signed by the same account that would commit, since revoking is committing
    ///         nothing. What a commitment already deployed stays deployed: this is not a rollback
    function revoke() public {
        ChainConfig memory config = Chains.load();
        address namespace_ = _namespace(config);

        // A Safe-held namespace is proposed to instead, and a proposing run broadcasts nothing
        bool broadcasting = !proposes(namespace_);
        if (broadcasting) vm.startBroadcast();

        // The suffix only shapes salts, and revoking commits none
        _initGated("", msg.sender, DeployPhase.Commit, namespace_, new address[](0));
        _revokeCommitment();

        if (broadcasting) vm.stopBroadcast();
    }

    /// @notice Deploys what has been committed, one transaction per contract, signed by an executor.
    ///         If it stops partway, resume it — never re-run either phase from scratch over a partial
    ///         deployment (see script/deploy/README.md).
    function deploy() public {
        _launch(DeployPhase.Deploy);
    }

    /// @dev One run per phase, always, so that every deployment is committed to on chain before any of it
    ///      is deployed, and so that testnets and anvil rehearse exactly what mainnet does. Running them
    ///      apart is also the only thing that proves the two agree: the deploy phase rebuilds every init
    ///      code in a fresh process, and has to land on exactly what the commit phase committed.
    function run() public virtual {
        revert(
            "A gated deployment is two separate runs. Pass --sig 'commit()' to commit it, "
            "then --sig 'deploy()' to deploy it"
        );
    }

    /// @dev A namespace can never be replaced, so on mainnet it is the Safe rather than a key, and it
    ///      delegates to whichever one signs the phase. Off mainnet, the signer keeps to its own addresses
    function _namespace(ChainConfig memory config) internal view returns (address) {
        return config.network.isMainnet() ? PROTOCOL_SAFE : vm.envOr("NAMESPACE", msg.sender);
    }

    function _launch(DeployPhase phase) internal {
        bool committing = phase == DeployPhase.Commit;

        ChainConfig memory config = Chains.load();
        // Only committing is the namespace's own call; deploying is signed by an executor key either way
        bool broadcasting = !committing || !proposes(_namespace(config));

        if (broadcasting) vm.startBroadcast();

        // Committing deploys nothing, so it reports nothing: the manifest belongs to the phase that deploys.
        // Opening it here and writing it below would replace the addresses of whatever was deployed last with
        // an empty set, leaving the deploy phase to put them back
        if (!committing) startDeploymentOutput(REPLACE);

        DeployerInput memory input = DeployerInput({
            centrifugeId: config.network.centrifugeId,
            suffix: config.network.isMainnet() ? "" : vm.envOr("SUFFIX", string("")),
            txLimits: config.network.buildBatchLimits(),
            protocolSafe: ISafe(config.network.protocolAdmin),
            opsSafe: ISafe(config.network.opsAdmin),
            root: config.rootAddress(),
            delay: config.network.isMainnet() ? MAINNET_DELAY : 0,
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
        if (config.network.isMainnet() && committing) {
            require(address(input.protocolSafe) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(input.opsSafe) == OPS_SAFE, "wrong ops admin");
        }

        address[] memory executors;
        if (committing) {
            executors = vm.envAddress("EXECUTORS", ",");
            require(executors.length > 0, "EXECUTORS must name at least one account");
        }

        deployFull(input, msg.sender, phase, _namespace(config), executors);

        // And the same on what the deployment produced, which the check above cannot speak for
        if (config.network.isMainnet() && !committing) {
            require(address(protocolGuardian.safe()) == PROTOCOL_SAFE, "wrong safe admin");
            require(address(opsGuardian.opsSafe()) == OPS_SAFE, "wrong ops admin");
        }

        if (!committing) saveDeploymentOutput(Chains.pathOf(config.network.name));

        if (broadcasting) vm.stopBroadcast();

        if (input.root != address(0)) _printRootFixes(input.root);
    }

    /// @dev Takes the Root rather than reading it back, so this reads the same in both phases: a validating
    ///      run rolls its walk back, and only `rootFixes` is carried across it
    function _printRootFixes(address keptRoot) internal view {
        console.log("");
        console.log("Root %s was reused, so this deployment is NOT complete:", keptRoot);
        console.log("the wiring only Root can do is waiting in RootFixes at %s", address(rootFixes));
        console.log("Cast it: scheduleRely, wait out root.delay(), executeScheduledRely, then rootFixes.cast()");
    }
}
