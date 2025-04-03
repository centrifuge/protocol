// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";
import {MessageDispatcher} from "src/common/MessageDispatcher.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

abstract contract CommonDeployer is Script, JsonRegistry {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;
    uint256 constant BASE_MSG_COST = 20000000000000000; // in Weight

    IAdapter[] adapters;

    Root public root;
    ISafe public adminSafe;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    constructor() {
        // If no salt is provided, a pseudo-random salt is generated,
        // thus effectively making the deployment non-deterministic
        SALT = vm.envOr(
            "DEPLOYMENT_SALT", keccak256(abi.encodePacked(string(abi.encodePacked(blockhash(block.number - 1)))))
        );
    }

    function deployCommon(uint16 chainId, ISafe adminSafe_, address deployer) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        root = new Root(DELAY, deployer);

        uint64 messageGasLimit = uint64(vm.envOr("MESSAGE_COST", BASE_MSG_COST));
        uint64 proofGasLimit = uint64(vm.envOr("PROOF_COST", BASE_MSG_COST));

        messageProcessor = new MessageProcessor(root, gasService, deployer);

        gasService = new GasService(messageGasLimit, proofGasLimit, messageProcessor);
        gateway = new Gateway(root, gasService);

        messageDispatcher = new MessageDispatcher(chainId, root, gateway, deployer);

        adminSafe = adminSafe_;

        // deployer is not actually an implementation of ISafe but for deployment this is not an issue
        guardian = new Guardian(ISafe(deployer), root, messageDispatcher);

        _commonRegister();
        _commonRely();
        _commonFile();
    }

    function _commonRegister() private {
        startDeploymentOutput();

        register("root", address(root));
        register("adminSafe", address(adminSafe));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));
    }

    function _commonRely() private {
        gasService.rely(address(root));
        root.rely(address(guardian));
        root.rely(address(messageProcessor));
        root.rely(address(messageDispatcher));
        gateway.rely(address(root));
        gateway.rely(address(guardian));
        gateway.rely(address(messageDispatcher));
        gateway.rely(address(messageProcessor));
        messageProcessor.rely(address(gateway));
        messageDispatcher.rely(address(guardian));
    }

    function _commonFile() private {
        messageProcessor.file("gateway", address(gateway));
        gateway.file("processor", address(messageProcessor));
    }

    function wire(uint16 chainId, IAdapter adapter, address deployer) public {
        adapters.push(adapter);
        gateway.file("adapters", chainId, adapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        guardian.file("safe", address(adminSafe));

        root.deny(deployer);
        gasService.deny(deployer);
        gateway.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
    }
}
