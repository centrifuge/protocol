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

contract CommonDeployer is Script, JsonRegistry {
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

    function deployCommon(uint16 chainId, ISafe adminSafe_) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        root = new Root(DELAY, address(this));

        adminSafe = adminSafe_;
        guardian = new Guardian(adminSafe, root);

        uint64 messageGasLimit = uint64(vm.envOr("MESSAGE_COST", BASE_MSG_COST));
        uint64 proofGasLimit = uint64(vm.envOr("PROOF_COST", BASE_MSG_COST));

        gasService = new GasService(messageGasLimit, proofGasLimit);
        gateway = new Gateway(root, gasService);
        messageProcessor = new MessageProcessor(root, gasService, address(this));
        messageDispatcher = new MessageDispatcher(chainId, gateway, address(this));

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
        messageProcessor.rely(address(gateway));
    }

    function _commonFile() private {
        gateway.file("handler", address(messageProcessor));
    }

    function wire(IAdapter adapter) public {
        adapters.push(adapter);
        gateway.file("adapters", adapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(address(this));
    }

    function removeCommonDeployerAccess() public {
        if (root.wards(address(this)) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        root.deny(address(this));
        gasService.deny(address(this));
        gateway.deny(address(this));
        messageProcessor.deny(address(this));
        messageDispatcher.deny(address(this));
    }
}
