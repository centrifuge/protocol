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
import {TokenRecoverer} from "src/common/TokenRecoverer.sol";

import {JsonRegistry} from "script/utils/JsonRegistry.s.sol";

import "forge-std/Script.sol";

string constant MESSAGE_COST_ENV = "MESSAGE_COST";
string constant MAX_BATCH_SIZE_ENV = "MAX_BATCH_SIZE";

abstract contract CommonDeployer is Script, JsonRegistry {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;
    uint128 constant FALLBACK_MSG_COST = uint128(0.02 ether); // in Weight
    uint128 constant FALLBACK_MAX_BATCH_SIZE = uint128(10_000_000 ether); // 10M in Weight

    IAdapter[] adapters;

    ISafe public adminSafe;
    Root public root;
    TokenRecoverer public tokenRecoverer;
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

    function deployCommon(uint16 centrifugeId, ISafe adminSafe_, address deployer, bool isTests) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        startDeploymentOutput(isTests);

        uint128 messageGasLimit = uint128(vm.envOr(MESSAGE_COST_ENV, FALLBACK_MSG_COST));
        uint128 maxBatchSize = uint128(vm.envOr(MAX_BATCH_SIZE_ENV, FALLBACK_MAX_BATCH_SIZE));

        root = new Root(DELAY, deployer);
        tokenRecoverer = new TokenRecoverer(root, deployer);

        messageProcessor = new MessageProcessor(root, tokenRecoverer, deployer);

        gasService = new GasService(maxBatchSize, messageGasLimit);
        gateway = new Gateway(centrifugeId, root, gasService, deployer);

        messageDispatcher = new MessageDispatcher(centrifugeId, root, gateway, tokenRecoverer, deployer);

        adminSafe = adminSafe_;

        // deployer is not actually an implementation of ISafe but for deployment this is not an issue
        guardian = new Guardian(ISafe(deployer), root, messageDispatcher);

        _commonRegister();
        _commonRely();
        _commonFile();
    }

    function _commonRegister() private {
        register("root", address(root));
        register("adminSafe", address(adminSafe));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("messageProcessor", address(messageProcessor));
        register("messageDispatcher", address(messageDispatcher));
    }

    function _commonRely() private {
        root.rely(address(guardian));
        root.rely(address(messageProcessor));
        root.rely(address(messageDispatcher));
        gateway.rely(address(root));
        gateway.rely(address(guardian));
        gateway.rely(address(messageDispatcher));
        gateway.rely(address(messageProcessor));
        messageDispatcher.rely(address(root));
        messageProcessor.rely(address(gateway));
        messageDispatcher.rely(address(guardian));
        tokenRecoverer.rely(address(messageDispatcher));
        tokenRecoverer.rely(address(messageProcessor));
    }

    function _commonFile() private {
        messageProcessor.file("gateway", address(gateway));
        gateway.file("processor", address(messageProcessor));
    }

    function wire(uint16 centrifugeId, IAdapter adapter, address deployer) public {
        adapters.push(adapter);
        gateway.file("adapters", centrifugeId, adapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        guardian.file("safe", address(adminSafe));

        root.deny(deployer);
        gateway.deny(deployer);
        tokenRecoverer.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
    }
}
