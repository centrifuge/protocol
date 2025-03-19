// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root} from "src/common/Root.sol";
import {GasService} from "src/common/GasService.sol";
import {Guardian, ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";

contract CommonDeployer is Script {
    uint256 constant DELAY = 48 hours;
    bytes32 immutable SALT;
    uint256 constant BASE_MSG_COST = 20000000000000000; // in Weight

    Root public root;
    ISafe public adminSafe;
    Guardian public guardian;
    GasService public gasService;

    constructor() {
        // If no salt is provided, a pseudo-random salt is generated,
        // thus effectively making the deployment non-deterministic
        SALT = vm.envOr(
            "DEPLOYMENT_SALT", keccak256(abi.encodePacked(string(abi.encodePacked(blockhash(block.number - 1)))))
        );
    }

    function deployCommon(ISafe adminSafe_, address deployer) public {
        if (address(root) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        root = new Root(DELAY, deployer);

        adminSafe = adminSafe_;
        guardian = new Guardian(adminSafe, root);

        uint64 messageGasLimit = uint64(vm.envOr("MESSAGE_COST", BASE_MSG_COST));
        uint64 proofGasLimit = uint64(vm.envOr("PROOF_COST", BASE_MSG_COST));

        gasService = new GasService(messageGasLimit, proofGasLimit);

        _commonRely();
    }

    function _commonRely() private {
        gasService.rely(address(root));
        root.rely(address(guardian));
    }

    function removeCommonDeployerAccess(address deployer) public {
        if (root.wards(deployer) == 0) {
            return; // Already access removed. Make this method idempotent.
        }

        root.deny(deployer);
        gasService.deny(deployer);
    }
}
