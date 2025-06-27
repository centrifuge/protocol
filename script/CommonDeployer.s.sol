// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {GasService} from "src/common/GasService.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {TokenRecoverer} from "src/common/TokenRecoverer.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {MessageDispatcher} from "src/common/MessageDispatcher.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

struct CommonInput {
    uint16 centrifugeId;
    ISafe adminSafe;
    uint128 messageGasLimit;
    uint128 maxBatchSize;
    bool isTests;
}

abstract contract CommonDeployer is Script, JsonRegistry, CreateXScript {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;

    string version;
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
        version = vm.envOr("VERSION", string(""));
    }

    /**
     * @dev Generates a salt for contract deployment
     * @param contractName The name of the contract
     * @return salt A deterministic salt based on contract name and optional VERSION
     */
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        if (bytes(version).length > 0) {
            return keccak256(abi.encodePacked(contractName, version));
        }
        return keccak256(abi.encodePacked(contractName));
    }

    function deployCommon(CommonInput memory input, address deployer) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        if (input.isTests) {
            // For tests we want to have different contract addreses per chain
            version = string(abi.encodePacked(version, input.centrifugeId));
        }

        setUpCreateXFactory();
        startDeploymentOutput(input.isTests);

        // Note: This function was split into smaller helper functions to avoid
        // "stack too deep" compilation errors that occur when too many local
        // variables are used in a single function scope.

        // Deploy basic contracts first
        _deployBasicContracts(deployer, input.messageGasLimit, input.maxBatchSize);

        // Deploy more complex contracts
        _deployComplexContracts(input.centrifugeId, deployer);

        adminSafe = input.adminSafe;

        _commonRegister();
        _commonRely();
        _commonFile();
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
        gateway.rely(address(multiAdapter));
        multiAdapter.rely(address(root));
        multiAdapter.rely(address(guardian));
        multiAdapter.rely(address(gateway));
        messageDispatcher.rely(address(root));
        messageDispatcher.rely(address(guardian));
        messageProcessor.rely(address(root));
        messageProcessor.rely(address(gateway));
        tokenRecoverer.rely(address(root));
        tokenRecoverer.rely(address(messageDispatcher));
        tokenRecoverer.rely(address(messageProcessor));
        poolEscrowFactory.rely(address(root));
    }

    function _commonFile() private {
        gateway.file("processor", address(messageProcessor));
        gateway.file("adapter", address(multiAdapter));
        poolEscrowFactory.file("gateway", address(gateway));
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

    // Helper function to deploy basic contracts in a separate scope to avoid stack too deep errors
    function _deployBasicContracts(address deployer, uint128 messageGasLimit, uint128 maxBatchSize) private {
        // Root
        bytes32 rootSalt = generateSalt("root");
        bytes memory rootBytecode = abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, deployer));
        root = Root(create3(rootSalt, rootBytecode));

        // TokenRecoverer
        bytes32 tokenRecovererSalt = generateSalt("tokenRecoverer");
        bytes memory tokenRecovererBytecode =
            abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, deployer));
        tokenRecoverer = TokenRecoverer(create3(tokenRecovererSalt, tokenRecovererBytecode));

        // MessageProcessor
        bytes32 messageProcessorSalt = generateSalt("messageProcessor");
        bytes memory messageProcessorBytecode =
            abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, tokenRecoverer, deployer));
        messageProcessor = MessageProcessor(create3(messageProcessorSalt, messageProcessorBytecode));

        // GasService
        bytes32 gasServiceSalt = generateSalt("gasService");
        bytes memory gasServiceBytecode =
            abi.encodePacked(type(GasService).creationCode, abi.encode(maxBatchSize, messageGasLimit));
        gasService = GasService(create3(gasServiceSalt, gasServiceBytecode));
    }

    // Helper function to deploy more complex contracts in a separate scope to avoid stack too deep errors
    function _deployComplexContracts(uint16 centrifugeId_, address deployer) private {
        // Gateway
        bytes32 gatewaySalt = generateSalt("gateway");
        bytes memory gatewayBytecode =
            abi.encodePacked(type(Gateway).creationCode, abi.encode(root, gasService, deployer));
        gateway = Gateway(payable(create3(gatewaySalt, gatewayBytecode)));

        // MultiAdapter
        bytes32 multiAdapterSalt = generateSalt("multiAdapter");
        bytes memory multiAdapterBytecode =
            abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(centrifugeId_, gateway, deployer));
        multiAdapter = MultiAdapter(create3(multiAdapterSalt, multiAdapterBytecode));

        // MessageDispatcher - use intermediate variables to avoid stack too deep
        bytes32 messageDispatcherSalt = generateSalt("messageDispatcher");

        // Store variables to reduce stack pressure
        address rootAddr = address(root);
        address gatewayAddr = address(gateway);
        address tokenRecovererAddr = address(tokenRecoverer);

        bytes memory messageDispatcherBytecode = abi.encodePacked(
            type(MessageDispatcher).creationCode,
            abi.encode(centrifugeId_, rootAddr, gatewayAddr, tokenRecovererAddr, deployer)
        );
        messageDispatcher = MessageDispatcher(create3(messageDispatcherSalt, messageDispatcherBytecode));

        // Guardian - use intermediate variables to avoid stack too deep
        bytes32 guardianSalt = generateSalt("guardian");

        // Store variables to reduce stack pressure
        address multiAdapterAddr = address(multiAdapter);
        address messageDispatcherAddr = address(messageDispatcher);

        bytes memory guardianBytecode = abi.encodePacked(
            type(Guardian).creationCode, abi.encode(ISafe(deployer), multiAdapterAddr, rootAddr, messageDispatcherAddr)
        );
        guardian = Guardian(create3(guardianSalt, guardianBytecode));

        // PoolEscrowFactory
        poolEscrowFactory = _deployPoolEscrowFactory(deployer);
    }

    // Helper function to deploy PoolEscrowFactory in a separate scope to avoid stack too deep errors
    function _deployPoolEscrowFactory(address deployer) private returns (PoolEscrowFactory) {
        bytes32 poolEscrowFactorySalt = generateSalt("poolEscrowFactory");
        bytes memory poolEscrowFactoryBytecode =
            abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(address(root), deployer));
        return PoolEscrowFactory(create3(poolEscrowFactorySalt, poolEscrowFactoryBytecode));
    }
}
