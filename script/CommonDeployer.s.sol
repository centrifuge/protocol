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
import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

abstract contract CommonDeployer is Script, JsonRegistry, CreateXScript {
    uint256 constant DELAY = 48 hours;
    uint256 constant BASE_MSG_COST = 20000000000000000; // in Weight

    IAdapter[] adapters;

    Root public root;
    ISafe public adminSafe;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MessageProcessor public messageProcessor;
    MessageDispatcher public messageDispatcher;

    function setUp() public virtual withCreateX {}

    function deployCommon(uint16 chainId, ISafe adminSafe_, address deployer) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        root = Root(create3(bytes32("root"), abi.encodePacked(type(Root).creationCode, abi.encode(DELAY, deployer))));

        uint64 messageGasLimit = uint64(vm.envOr("MESSAGE_COST", BASE_MSG_COST));
        uint64 proofGasLimit = uint64(vm.envOr("PROOF_COST", BASE_MSG_COST));

        gasService = new GasService(messageGasLimit, proofGasLimit);
        gateway = new Gateway(root, gasService);

        messageProcessor = new MessageProcessor(root, gasService, deployer);
        messageDispatcher = new MessageDispatcher(chainId, root, gateway, deployer);

        adminSafe = adminSafe_;
        guardian = new Guardian(adminSafe, root, messageDispatcher);

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
        messageDispatcher.rely(address(guardian));
    }

    function _commonFile() private {
        gateway.file("handler", address(messageProcessor));
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

        root.deny(deployer);
        gasService.deny(deployer);
        gateway.deny(deployer);
        messageProcessor.deny(deployer);
        messageDispatcher.deny(deployer);
    }

    /// @notice To be used when we want to generate a vanity address, where the salt is passed on deployment
    /// @dev    If no salt is provided, a pseudo-random salt is generated,
    ///         thus effectively making the deployment non-deterministic
    function _getSalt(string memory name) internal returns (bytes32) {
        return vm.envOr(name, keccak256(abi.encodePacked(string(abi.encodePacked(blockhash(block.number - 1))))));
    }
}
