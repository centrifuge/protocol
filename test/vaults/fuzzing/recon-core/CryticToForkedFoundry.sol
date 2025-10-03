// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract CryticToForkedFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();

        // Setup forked environment
        string memory ECHIDNA_RPC_URL = vm.envString("ECHIDNA_RPC_URL");
        uint256 ECHIDNA_RPC_BLOCK = vm.envUint("ECHIDNA_RPC_BLOCK");
        // TODO: when testing locally change this block with block from coverage report set inside setupFork
        vm.createSelectFork(ECHIDNA_RPC_URL, ECHIDNA_RPC_BLOCK);
        setupFork();
    }
}
