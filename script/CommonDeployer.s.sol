// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {MessageProcessor} from "src/common/MessageProcessor.sol";

import "forge-std/Script.sol";

contract CommonDeployer is Script {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;
    uint256 constant BASE_MSG_COST = 20000000000000000; // in Weight

    string deploymentOutput;
    uint256 registeredContracts = 0;

    IAdapter[] adapters;

    Root public root;
    ISafe public adminSafe;
    Guardian public guardian;
    GasService public gasService;
    Gateway public gateway;
    MessageProcessor public messageProcessor;

    uint16 public cchainId;

    constructor() {
        // If no salt is provided, a pseudo-random salt is generated,
        // thus effectively making the deployment non-deterministic
        SALT = vm.envOr(
            "DEPLOYMENT_SALT", keccak256(abi.encodePacked(string(abi.encodePacked(blockhash(block.number - 1)))))
        );
    }

    function deployCommon(uint16 centrifugeChainId, ISafe adminSafe_, address deployer) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        cchainId = centrifugeChainId;

        root = new Root(DELAY, deployer);

        adminSafe = adminSafe_;
        guardian = new Guardian(adminSafe, root);

        uint64 messageGasLimit = uint64(vm.envOr("MESSAGE_COST", BASE_MSG_COST));
        uint64 proofGasLimit = uint64(vm.envOr("PROOF_COST", BASE_MSG_COST));

        gasService = new GasService(messageGasLimit, proofGasLimit);
        gateway = new Gateway(root, gasService);
        messageProcessor = new MessageProcessor(centrifugeChainId, gateway, root, gasService, deployer);

        _commonRegister();
        _commonRely();
        _commonFile();
    }

    function _commonRegister() private {
        deploymentOutput = '{\n  "contracts": {\n';

        register("root", address(root));
        register("adminSafe", address(adminSafe));
        register("guardian", address(guardian));
        register("gasService", address(gasService));
        register("gateway", address(gateway));
        register("messageProcessor", address(messageProcessor));
    }

    function _commonRely() private {
        gasService.rely(address(root));
        root.rely(address(guardian));
        root.rely(address(messageProcessor));
        gateway.rely(address(root));
        gateway.rely(address(guardian));
        gateway.rely(address(messageProcessor));
        messageProcessor.rely(address(gateway));
    }

    function _commonFile() private {
        gateway.file("handler", address(messageProcessor));
    }

    function wire(IAdapter adapter, address deployer) public {
        adapters.push(adapter);
        gateway.file("adapters", adapters);
        IAuth(address(adapter)).rely(address(root));
        IAuth(address(adapter)).deny(deployer);
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already access removed. Make this method idempotent.
        }

        root.deny(deployer);
        gasService.deny(deployer);
        gateway.deny(deployer);
        messageProcessor.deny(deployer);
    }

    function register(string memory name, address target) public {
        deploymentOutput = (registeredContracts == 0)
            ? string(abi.encodePacked(deploymentOutput, '    "', name, '": "0x', _toString(target), '"'))
            : string(abi.encodePacked(deploymentOutput, ',\n    "', name, '": "0x', _toString(target), '"'));

        registeredContracts += 1;
    }

    function saveDeploymentOutput() public {
        string memory path = string(
            abi.encodePacked(
                "./deployments/latest/", _toString(block.chainid), "_", _toString(block.timestamp), ".json"
            )
        );
        deploymentOutput = string(abi.encodePacked(deploymentOutput, "\n  }\n}\n"));
        vm.writeFile(path, deploymentOutput);
    }

    function _toString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint256 i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint256(uint160(x)) / (2 ** (8 * (19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2 * i] = _char(hi);
            s[2 * i + 1] = _char(lo);
        }
        return string(s);
    }

    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }

    function _toString(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
