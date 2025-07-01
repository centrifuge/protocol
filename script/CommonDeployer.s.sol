// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Gateway} from "src/common/Gateway.sol";
import {Root, IRoot} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {TokenRecoverer} from "src/common/TokenRecoverer.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {MultiAdapter} from "src/common/adapters/MultiAdapter.sol";
import {MessageDispatcher} from "src/common/MessageDispatcher.sol";
import {PoolEscrowFactory} from "src/common/factories/PoolEscrowFactory.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

struct CommonInput {
    uint16 centrifugeId;
    IRoot root;
    ISafe adminSafe;
    uint128 messageGasLimit;
    uint128 maxBatchSize;
    bytes32 version;
}

abstract contract CommonCBD {
    uint256 constant DELAY = 48 hours;

    bytes32 transient version;
    bool public transient newRoot;
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

    /**
     * @dev Generates a salt for contract deployment
     * @param contractName The name of the contract
     * @return salt A deterministic salt based on contract name and optional VERSION
     */
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        if (version != bytes32(0)) {
            return keccak256(abi.encodePacked(contractName, version));
        }
        return keccak256(abi.encodePacked(contractName));
    }

    function deployCommon(CommonInput memory input, ICreateX createX, address deployer) public {
        if (address(gateway) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        adminSafe = input.adminSafe;
        version = input.version;

        if (address(input.root) == address(0)) {
            newRoot = true;
            root = Root(
                createX.deployCreate3(
                    generateSalt("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, deployer))
                )
            );
        } else {
            root = Root(address(input.root));
        }

        tokenRecoverer = TokenRecoverer(
            createX.deployCreate3(
                generateSalt("tokenRecoverer"),
                abi.encodePacked(type(TokenRecoverer).creationCode, abi.encode(root, deployer))
            )
        );

        messageProcessor = MessageProcessor(
            createX.deployCreate3(
                generateSalt("messageProcessor"),
                abi.encodePacked(type(MessageProcessor).creationCode, abi.encode(root, tokenRecoverer, deployer))
            )
        );

        gasService = GasService(
            createX.deployCreate3(
                generateSalt("gasService"),
                abi.encodePacked(type(GasService).creationCode, abi.encode(input.maxBatchSize, input.messageGasLimit))
            )
        );

        gateway = Gateway(
            payable(
                createX.deployCreate3(
                    generateSalt("gateway"),
                    abi.encodePacked(type(Gateway).creationCode, abi.encode(root, gasService, deployer))
                )
            )
        );

        multiAdapter = MultiAdapter(
            createX.deployCreate3(
                generateSalt("multiAdapter"),
                abi.encodePacked(type(MultiAdapter).creationCode, abi.encode(input.centrifugeId, gateway, deployer))
            )
        );

        messageDispatcher = MessageDispatcher(
            createX.deployCreate3(
                generateSalt("messageDispatcher"),
                abi.encodePacked(
                    type(MessageDispatcher).creationCode,
                    abi.encode(input.centrifugeId, root, gateway, tokenRecoverer, deployer)
                )
            )
        );

        guardian = Guardian(
            createX.deployCreate3(
                generateSalt("guardian"),
                abi.encodePacked(
                    type(Guardian).creationCode, abi.encode(ISafe(deployer), multiAdapter, root, messageDispatcher)
                )
            )
        );

        poolEscrowFactory = PoolEscrowFactory(
            createX.deployCreate3(
                generateSalt("poolEscrowFactory"),
                abi.encodePacked(type(PoolEscrowFactory).creationCode, abi.encode(address(root), deployer))
            )
        );

        _commonRely();
        _commonFile();
    }

    function _commonRely() private {
        if (newRoot) {
            root.rely(address(guardian));
            root.rely(address(messageProcessor));
            root.rely(address(messageDispatcher));
        }
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

        // We override the deployer with the correct admin once everything is deployed
        guardian.file("safe", address(adminSafe));

        if (newRoot) {
            root.deny(deployer);
        }
        gateway.deny(deployer);
        multiAdapter.deny(deployer);
        tokenRecoverer.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
        poolEscrowFactory.deny(deployer);
    }
}

abstract contract CommonDeployer is Script, CommonCBD, JsonRegistry, CreateXScript {
    bool wasCommonRegistered;

    function deployCommon(CommonInput memory input, address deployer) public {
        super.deployCommon(input, _createX(), deployer);
    }

    function commonRegister() internal {
        if (wasCommonRegistered) return;
        wasCommonRegistered = true;

        if (newRoot) {
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

    function _createX() internal withCreateX returns (ICreateX) {
        return CreateX;
    }
}
