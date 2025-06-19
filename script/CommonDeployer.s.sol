// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {GasService} from "src/common/GasService.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {TokenRecoverer} from "src/common/TokenRecoverer.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {MessageDispatcher} from "src/common/MessageDispatcher.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

string constant MESSAGE_COST_ENV = "MESSAGE_COST";
string constant MAX_BATCH_SIZE_ENV = "MAX_BATCH_SIZE";

abstract contract CommonDeployer is Script, JsonRegistry {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;
    uint128 constant FALLBACK_MSG_COST = uint128(1_000_000); // in GAS
    uint128 constant FALLBACK_MAX_BATCH_SIZE = uint128(10_000_000); // 10M in Weight

    ISafe public adminSafe;
    Root public root;
    TokenRecoverer public tokenRecoverer;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MultiAdapter public multiAdapter;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;
    PoolEscrowFactory public poolEscrowFactory;

    constructor() {
        // If no salt is provided, a pseudo-random salt is generated,
        // thus effectively making the deployment non-deterministic
        SALT = vm.envOr("DEPLOYMENT_SALT", keccak256(abi.encodePacked(string(abi.encodePacked(block.timestamp)))));
    }

    function deployCommon(uint16 centrifugeId_, ISafe adminSafe_, address deployer, bool isTests) public virtual {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        startDeploymentOutput(isTests);

        uint128 messageGasLimit = uint128(vm.envOr(MESSAGE_COST_ENV, FALLBACK_MSG_COST));
        uint128 maxBatchSize = uint128(vm.envOr(MAX_BATCH_SIZE_ENV, FALLBACK_MAX_BATCH_SIZE));

        // Get the base salt from the FullDeployer
        bytes32 baseSalt = getBaseSalt();
        
        console.log("Deploying Common contracts with CreateX...");

        // Root
        bytes32 rootSalt = keccak256(abi.encodePacked(baseSalt, "root"));
        bytes memory rootBytecode = abi.encodePacked(
            type(Root).creationCode,
            abi.encode(DELAY, deployer)
        );
        root = Root(create3(rootSalt, rootBytecode));
        console.log("Root deployed at:", address(root));

        // TokenRecoverer
        bytes32 tokenRecovererSalt = keccak256(abi.encodePacked(baseSalt, "tokenRecoverer"));
        bytes memory tokenRecovererBytecode = abi.encodePacked(
            type(TokenRecoverer).creationCode,
            abi.encode(root, deployer)
        );
        tokenRecoverer = TokenRecoverer(create3(tokenRecovererSalt, tokenRecovererBytecode));
        console.log("TokenRecoverer deployed at:", address(tokenRecoverer));

        // MessageProcessor
        bytes32 messageProcessorSalt = keccak256(abi.encodePacked(baseSalt, "messageProcessor"));
        bytes memory messageProcessorBytecode = abi.encodePacked(
            type(MessageProcessor).creationCode,
            abi.encode(root, tokenRecoverer, deployer)
        );
        messageProcessor = MessageProcessor(create3(messageProcessorSalt, messageProcessorBytecode));
        console.log("MessageProcessor deployed at:", address(messageProcessor));

        // GasService
        bytes32 gasServiceSalt = keccak256(abi.encodePacked(baseSalt, "gasService"));
        bytes memory gasServiceBytecode = abi.encodePacked(
            type(GasService).creationCode,
            abi.encode(maxBatchSize, messageGasLimit)
        );
        gasService = GasService(create3(gasServiceSalt, gasServiceBytecode));
        console.log("GasService deployed at:", address(gasService));

        // Gateway
        bytes32 gatewaySalt = keccak256(abi.encodePacked(baseSalt, "gateway"));
        bytes memory gatewayBytecode = abi.encodePacked(
            type(Gateway).creationCode,
            abi.encode(root, gasService, deployer)
        );
        gateway = Gateway(create3(gatewaySalt, gatewayBytecode));
        console.log("Gateway deployed at:", address(gateway));

        // MultiAdapter
        bytes32 multiAdapterSalt = keccak256(abi.encodePacked(baseSalt, "multiAdapter"));
        bytes memory multiAdapterBytecode = abi.encodePacked(
            type(MultiAdapter).creationCode,
            abi.encode(centrifugeId_, gateway, deployer)
        );
        multiAdapter = MultiAdapter(create3(multiAdapterSalt, multiAdapterBytecode));
        console.log("MultiAdapter deployed at:", address(multiAdapter));

        // MessageDispatcher
        bytes32 messageDispatcherSalt = keccak256(abi.encodePacked(baseSalt, "messageDispatcher"));
        bytes memory messageDispatcherBytecode = abi.encodePacked(
            type(MessageDispatcher).creationCode,
            abi.encode(centrifugeId_, root, gateway, tokenRecoverer, deployer)
        );
        messageDispatcher = MessageDispatcher(create3(messageDispatcherSalt, messageDispatcherBytecode));
        console.log("MessageDispatcher deployed at:", address(messageDispatcher));

        adminSafe = adminSafe_;

        // Guardian
        bytes32 guardianSalt = keccak256(abi.encodePacked(baseSalt, "guardian"));
        bytes memory guardianBytecode = abi.encodePacked(
            type(Guardian).creationCode,
            abi.encode(ISafe(deployer), multiAdapter, root, messageDispatcher)
        );
        guardian = Guardian(create3(guardianSalt, guardianBytecode));
        console.log("Guardian deployed at:", address(guardian));

        // PoolEscrowFactory
        bytes32 poolEscrowFactorySalt = keccak256(abi.encodePacked(baseSalt, "poolEscrowFactory"));
        bytes memory poolEscrowFactoryBytecode = abi.encodePacked(
            type(PoolEscrowFactory).creationCode,
            abi.encode(address(root), deployer)
        );
        poolEscrowFactory = PoolEscrowFactory(create3(poolEscrowFactorySalt, poolEscrowFactoryBytecode));
        console.log("PoolEscrowFactory deployed at:", address(poolEscrowFactory));

        _commonRegister();
        _commonRely();
        _commonFile();
    }

    // Virtual function to get the base salt - implemented by FullDeployer
    function getBaseSalt() internal view virtual returns (bytes32) {
        return SALT; // Fallback to the old SALT if not overridden
    }

    function _commonRegister() private {
        register("root", address(root));
        // Already present in load_vars.sh and not needed to be registered
        // register("adminSafe", address(adminSafe));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("multiAdapter", address(multiAdapter));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));
        register("poolEscrowFactory", address(poolEscrowFactory));
    }

    function _commonRely() private {
        root.rely(address(guardian));
        root.rely(address(messageProcessor));
        root.rely(address(messageDispatcher));
        gateway.rely(address(root));
        gateway.rely(address(messageDispatcher));
        gateway.rely(address(messageProcessor));
        gateway.rely(address(multiAdapter));
        multiAdapter.rely(address(root));
        multiAdapter.rely(address(guardian));
        multiAdapter.rely(address(gateway));
        messageDispatcher.rely(address(root));
        messageDispatcher.rely(address(guardian));
        messageProcessor.rely(address(root));
        messageProcessor.rely(address(gateway));
        tokenRecoverer.rely(address(messageDispatcher));
        tokenRecoverer.rely(address(messageProcessor));
        poolEscrowFactory.rely(address(root));
    }

    function _commonFile() private {
        gateway.file("processor", address(messageProcessor));
        gateway.file("adapter", address(multiAdapter));
        poolEscrowFactory.file("gateway", address(gateway));
    }
    // The centrifugeId_ here has to be the destination centrifuge_chain_id
    // Use WireAdapters.s.sol for automatic wiring of live multi-chains adapters

    function wire(uint16 centrifugeId_, IAdapter adapter, address deployer) public {
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);

        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = adapter;

        multiAdapter.file("adapters", centrifugeId_, adapters);
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        guardian.file("safe", address(adminSafe));

        root.deny(deployer);
        gateway.deny(deployer);
        multiAdapter.deny(deployer);
        tokenRecoverer.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
        poolEscrowFactory.deny(deployer);
    }
}
