// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Chains, ChainConfig, AdaptersConfig} from "./ChainConfig.s.sol";

import "forge-std/Vm.sol";

Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

struct ContractsConfig {
    // Admin
    address root;
    address protocolGuardian;
    address opsGuardian;
    address gasService;
    // Core
    address gateway;
    address multiAdapter;
    address messageProcessor;
    address messageDispatcher;
    address poolEscrowFactory;
    address hubRegistry;
    address accounting;
    address holdings;
    address shareClassManager;
    address hub;
    address hubHandler;
    address shareTokenRegistrar;
    address spoke;
    address spokeHandler;
    address spokeRegistry;
    address snapshotQueue;
    address envoy;
    // Vaults
    address asyncRequestManager;
    address syncManager;
    address asyncVaultFactory;
    address syncDepositVaultFactory;
    address vaultRouter;
    address refundEscrowFactory;
    address subsidyManager;
    address queueManager;
    address batchRequestManager;
    // Hooks
    address freezeOnlyHook;
    address fullRestrictionsHook;
    address freelyTransferableHook;
    address redemptionRestrictionsHook;
    // Spoke managers
    address onOffRampFactory;
    address shareManager;
    address accountingToken;
    address flashLoanHelper;
    address onchainPMFactory;
    address scriptHelpers;
    // Spoke manager guards
    address approvalGuard;
    address circuitBreakerGuard;
    address slippageGuard;
    // Adapter managers
    address adapterFailover;
    // Valuations
    address identityValuation;
    address oracleValuation;
    // Hub managers
    address navManager;
    address simplePriceManager;
    // Bridge
    address tokenBridge;
    // Bridge hooks
    address bridgeCircuitBreaker;
    // Adapters, required of the chains that declare them and of no others — see `_parseAdapters`
    address layerZeroAdapter;
    address axelarAdapter;
    address chainlinkAdapter;
    address hyperlaneAdapter;
}

/// @notice A whole `env/<environment>/<network>.json`: what the chain is, and what is deployed on it.
///
/// @dev    The halves are split because only one of them moves. A release adds contracts, retires others
///         and redeploys the lot, whereas `chain` describes the chain and its messaging and changes only
///         when the chain does. The dependency runs one way — this file reads a network's JSON through
///         `Chains`, and `ChainConfig` knows nothing of what is deployed on it — so a script that assumes
///         no deployment can take `ChainConfig` alone.
struct EnvConfig {
    ChainConfig chain;
    ContractsConfig contracts;
}

/// @notice Loads an env/<environment>/<network>.json in full, for the scripts that read back a deployment
///
/// @dev    `contracts` describes what *this* branch deploys, not what any chain happens to be running:
///         every field is read strictly, and a config that does not carry one fails the load. That is the
///         point of the reader — it is the schema `env/<environment>/<network>.json` has to satisfy, so a script never
///         works with `address(0)` where an address was meant. The configs of earlier releases do not
///         satisfy it and are not expected to: what this parses is what `LaunchDeployer` has just written.
///         Two things hold the pair together: `test_theParserReadsWhatTheDeployerWrites` parses the exact
///         JSON the registry would write for a full deployment, and `anvil.sh` runs the real round trip —
///         deploy, then `TestData` reading it back — on two local chains on every PR.
library Env {
    /// @notice Loads the config of the chain the run is pointed at, resolved by chain id
    function load() internal view returns (EnvConfig memory) {
        return load(Chains.detect());
    }

    /// @notice Same, for a network named outright
    function load(string memory network) internal view returns (EnvConfig memory config) {
        string memory json = Chains.jsonOf(network);

        config.chain = Chains.parse(json, network);
        config.contracts = parseContracts(json, config.chain.adapters);
    }

    /// @dev Every field here is required, and that is the whole design: this parser describes the set
    ///      `LaunchDeployer` deploys, so a config missing one of them is a config this branch did not
    ///      write, and failing the load is the right answer rather than handing a script `address(0)`.
    ///      Adding a contract to the release means adding it here; retiring one means deleting it here.
    ///      The only contracts kept out are the adapters, which are required of the chains that run them
    ///      and of no others — see `_parseAdapters`.
    function parseContracts(string memory json, AdaptersConfig memory adapters)
        internal
        view
        returns (ContractsConfig memory config)
    {
        // Once tolerated for a chain being prepared before anything was deployed on it — but the script
        // that runs before a deployment is `LaunchDeployer`, which reads the chain half alone and never
        // comes through here. Every remaining caller acts on a deployment, and none can do anything useful
        // with 54 zeros, so the honest answer is the same one every missing field gets: refuse.
        require(vm.keyExistsJson(json, ".contracts"), "config records no deployment: it has no .contracts");

        // Admin
        config.root = _required(json, "root");
        config.protocolGuardian = _required(json, "protocolGuardian");
        config.opsGuardian = _required(json, "opsGuardian");
        config.gasService = _required(json, "gasService");

        // Core
        config.gateway = _required(json, "gateway");
        config.multiAdapter = _required(json, "multiAdapter");
        config.messageProcessor = _required(json, "messageProcessor");
        config.messageDispatcher = _required(json, "messageDispatcher");
        config.poolEscrowFactory = _required(json, "poolEscrowFactory");
        config.hubRegistry = _required(json, "hubRegistry");
        config.accounting = _required(json, "accounting");
        config.holdings = _required(json, "holdings");
        config.shareClassManager = _required(json, "shareClassManager");
        config.hub = _required(json, "hub");
        config.hubHandler = _required(json, "hubHandler");
        config.shareTokenRegistrar = _required(json, "shareTokenRegistrar");
        config.spoke = _required(json, "spoke");
        config.spokeHandler = _required(json, "spokeHandler");
        config.spokeRegistry = _required(json, "spokeRegistry");
        config.snapshotQueue = _required(json, "snapshotQueue");
        config.envoy = _required(json, "envoy");

        // Vaults
        config.asyncRequestManager = _required(json, "asyncRequestManager");
        config.syncManager = _required(json, "syncManager");
        config.asyncVaultFactory = _required(json, "asyncVaultFactory");
        config.syncDepositVaultFactory = _required(json, "syncDepositVaultFactory");
        config.vaultRouter = _required(json, "vaultRouter");
        config.refundEscrowFactory = _required(json, "refundEscrowFactory");
        config.subsidyManager = _required(json, "subsidyManager");
        config.queueManager = _required(json, "queueManager");
        config.batchRequestManager = _required(json, "batchRequestManager");

        // Hooks
        config.freezeOnlyHook = _required(json, "freezeOnlyHook");
        config.fullRestrictionsHook = _required(json, "fullRestrictionsHook");
        config.freelyTransferableHook = _required(json, "freelyTransferableHook");
        config.redemptionRestrictionsHook = _required(json, "redemptionRestrictionsHook");

        // Spoke managers
        config.onOffRampFactory = _required(json, "onOffRampFactory");
        config.shareManager = _required(json, "shareManager");
        config.accountingToken = _required(json, "accountingToken");
        config.flashLoanHelper = _required(json, "flashLoanHelper");
        config.onchainPMFactory = _required(json, "onchainPMFactory");
        config.scriptHelpers = _required(json, "scriptHelpers");
        config.approvalGuard = _required(json, "approvalGuard");
        config.circuitBreakerGuard = _required(json, "circuitBreakerGuard");
        config.slippageGuard = _required(json, "slippageGuard");

        // Adapter managers
        config.adapterFailover = _required(json, "adapterFailover");

        // Valuations
        config.identityValuation = _required(json, "identityValuation");
        config.oracleValuation = _required(json, "oracleValuation");

        // Hub managers
        config.navManager = _required(json, "navManager");
        config.simplePriceManager = _required(json, "simplePriceManager");

        // Bridge
        config.tokenBridge = _required(json, "tokenBridge");

        // Bridge hooks
        config.bridgeCircuitBreaker = _required(json, "bridgeCircuitBreaker");

        _parseAdapters(json, adapters, config);
    }

    /// @dev Conditional rather than lenient: `deploy` in the chain half is the same flag `FullDeployer`
    ///      branches on to decide whether to deploy an adapter at all, so a chain that claims one has to
    ///      carry its address, and a chain that claims none is complete without any. Nothing here is read
    ///      leniently — a config naming three of the four is right or wrong, never merely incomplete.
    function _parseAdapters(string memory json, AdaptersConfig memory adapters, ContractsConfig memory config)
        private
        view
    {
        config.layerZeroAdapter = _adapter(json, "layerZeroAdapter", adapters.layerZero.deploy);
        config.axelarAdapter = _adapter(json, "axelarAdapter", adapters.axelar.deploy);
        config.chainlinkAdapter = _adapter(json, "chainlinkAdapter", adapters.chainlink.deploy);
        config.hyperlaneAdapter = _adapter(json, "hyperlaneAdapter", adapters.hyperlane.deploy);
    }

    /// @dev An adapter the chain half declares must be recorded; one it does not declare must not be. The
    ///      second half is a rejection rather than a silent zero: a config carrying an address under a
    ///      `deploy: false` flag is contradicting itself, and handing readers `address(0)` for a contract
    ///      the file plainly names would be the quiet kind of wrong this parser exists to refuse.
    function _adapter(string memory json, string memory key, bool deployed) private view returns (address) {
        if (deployed) return _required(json, key);

        require(
            !vm.keyExistsJson(json, string.concat(".contracts.", key)),
            string.concat("chain declares no ", key, " but the config records one")
        );
        return address(0);
    }

    /// @notice Reads a contract the config must carry, reverting the load if it does not
    function _required(string memory json, string memory key) private pure returns (address) {
        return vm.parseJsonAddress(json, string.concat(".contracts.", key, ".address"));
    }
}
