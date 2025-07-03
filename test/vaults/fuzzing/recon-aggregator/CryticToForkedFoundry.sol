// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {vm} from "@chimera/Hevm.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {TargetFunctions} from "test/vaults/fuzzing/recon-aggregator/TargetFunctions.sol";

contract CryticToFoundryRouter is Test, TargetFunctions, FoundryAsserts {
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
