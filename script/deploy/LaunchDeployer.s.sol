// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountLib} from "./BaseDeployer.s.sol";
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
///
///         Each phase acts as `--sender`. Deploying, that is an executor key. Committing, it is the namespace
///         or a delegate of it, and how the phase is signed follows from what that account is: a key
///         broadcasts, a Safe is proposed to — signed by the owner on the Ledger, which the run asks the
///         device for. Nothing here assumes which the namespace is or which its delegates are.
contract LaunchDeployer is FullDeployer {
    using AccountLib for address;

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

        // A Safe is proposed to instead, and a proposing run broadcasts nothing
        bool broadcasting = !msg.sender.isSafeAccount();
        if (broadcasting) vm.startBroadcast();

        // The deployment id only shapes salts, and revoking commits none
        _initGated("", DeployPhase.Commit, config.network.namespace, new address[](0));
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

    function _launch(DeployPhase phase) internal {
        ChainConfig memory config = Chains.load();

        bool committing = phase == DeployPhase.Commit;
        bool broadcasting = !committing || !msg.sender.isSafeAccount();
        if (broadcasting) vm.startBroadcast();

        // Committing deploys nothing, so it reports nothing: the manifest belongs to the phase that deploys.
        // Opening it here and writing it below would replace the addresses of whatever was deployed last with
        // an empty set, leaving the deploy phase to put them back
        if (!committing) startDeploymentOutput(REPLACE);

        DeployerInput memory input = DeployerInput({
            centrifugeId: config.network.centrifugeId,
            deploymentId: config.network.deploymentId,
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

        address[] memory executors;
        if (committing) {
            executors = vm.envAddress("EXECUTORS", ",");
            require(executors.length > 0, "EXECUTORS must name at least one account");

            // The guardians have no wards: a wrong admin on a fresh chain is unrecoverable
            if (config.network.isMainnet()) {
                require(config.network.protocolAdmin.isSafeAccount(), "mainnet protocolAdmin is not a Safe");
                require(config.network.opsAdmin.isSafeAccount(), "mainnet opsAdmin is not a Safe");
                require(config.network.protocolAdmin != config.network.opsAdmin, "mainnet admins coincide");
            }
        }

        deployFull(input, phase, config.network.namespace, executors);

        // The deployment wired what the config asked for
        if (!committing) {
            require(address(protocolGuardian.safe()) == config.network.protocolAdmin, "wrong safe admin");
            require(address(opsGuardian.opsSafe()) == config.network.opsAdmin, "wrong ops admin");
            // Written back to the file it was read from, named by the deployment the config declares: the
            // run's output belongs to that directory and to no sibling of it
            saveDeploymentOutput(Chains.pathOf(config.network.name, config.network.environment));
        }

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
