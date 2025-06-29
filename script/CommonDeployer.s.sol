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

    function deployCommon(uint16 centrifugeId_, ISafe adminSafe_, address deployer, bool isTests) public {
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
        gateway = new Gateway(root, gasService, deployer);
        multiAdapter = new MultiAdapter(centrifugeId_, gateway, deployer);

        messageDispatcher = new MessageDispatcher(centrifugeId_, root, gateway, tokenRecoverer, deployer);

        adminSafe = adminSafe_;

        // deployer is not actually an implementation of ISafe but for deployment this is not an issue
        guardian = new Guardian(ISafe(deployer), multiAdapter, root, messageDispatcher);

        poolEscrowFactory = new PoolEscrowFactory{salt: SALT}(address(root), deployer);

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
}
