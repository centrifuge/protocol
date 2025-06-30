// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root, IRoot} from "src/common/Root.sol";
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
    IRoot root;
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
        if (address(gateway) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        if (input.isTests) {
            // For tests we want to have different contract addreses per chain
            version = string(abi.encodePacked(version, input.centrifugeId));
        }

        setUpCreateXFactory();
        startDeploymentOutput(input.isTests);

        adminSafe = input.adminSafe;

        if (address(input.root) == address(0)) {
            root = Root(
                create3(generateSalt("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, deployer)))
            );
        } else {
            root = Root(address(input.root));
        }

        tokenRecoverer = TokenRecoverer(
            create3(
                generateSalt("tokenRecoverer"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, deployer))
            )
        );

        messageProcessor = MessageProcessor(
            create3(
                generateSalt("messageProcessor"),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, tokenRecoverer, deployer))
            )
        );

        gasService = GasService(
            create3(
                generateSalt("gasService"),
                abi.encodePacked(type(GasService).creationCode, abi.encode(input.maxBatchSize, input.messageGasLimit))
            )
        );

        gateway = Gateway(
            payable(
                create3(
                    generateSalt("gateway"),
                    abi.encodePacked(type(Gateway).creationCode, abi.encode(root, gasService, deployer))
                )
            )
        );

        multiAdapter = MultiAdapter(
            create3(
                generateSalt("multiAdapter"),
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, deployer))
            )
        );

        messageDispatcher = MessageDispatcher(
            create3(
                generateSalt("messageDispatcher"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode,
                    abi.encode(input.centrifugeId, root, gateway, tokenRecoverer, deployer)
                )
            )
        );

        guardian = Guardian(
            create3(
                generateSalt("guardian"),
                abi.encodePacked(
                    type(Guardian).creationCode, abi.encode(ISafe(deployer), multiAdapter, root, messageDispatcher)
                )
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            create3(
                generateSalt("poolEscrowFactory"),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(address(root), deployer))
            )
        );

        _commonRegister(address(input.root));
        _commonRely();
        _commonFile();
    }

    function _commonRegister(address inputRoot) private {
        if (inputRoot == address(0)) {
            register("root", address(root));
            // Otherwise already present in load_vars.sh and not needed to be registered
        }
        // register("adminSafe", address(adminSafe)); => Already present in load_vars.sh and not needed to be registered
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
        if (gateway.wards(deployer) == 0) {
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
