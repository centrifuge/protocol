// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConfig, Env} from "../../script/utils/EnvConfig.s.sol";
import "forge-std/Test.sol";

// NOTE: the action of parse the config file does the biggest validation part
contract EnvMainnetFilesTest is Test {
    function test_parseEthereum() public view {
        EnvConfig memory config = Env.load("ethereum");
        assertEq(config.network.centrifugeId, 1);
        config.network.buildBatchLimits();
    }

    function test_parseBase() public view {
        EnvConfig memory config = Env.load("base");
        assertEq(config.network.centrifugeId, 2);
        config.network.buildBatchLimits();
    }

    function test_parseArbitrum() public view {
        EnvConfig memory config = Env.load("arbitrum");
        assertEq(config.network.centrifugeId, 3);
        config.network.buildBatchLimits();
    }

    function test_parsePlume() public view {
        EnvConfig memory config = Env.load("plume");
        assertEq(config.network.centrifugeId, 4);
        config.network.buildBatchLimits();
    }

    function test_parseAvalanche() public view {
        EnvConfig memory config = Env.load("avalanche");
        assertEq(config.network.centrifugeId, 5);
        config.network.buildBatchLimits();
    }

    function test_parseBnbSmartChain() public view {
        EnvConfig memory config = Env.load("bnb-smart-chain");
        assertEq(config.network.centrifugeId, 6);
        config.network.buildBatchLimits();
    }

    function test_parseHyperEvm() public view {
        EnvConfig memory config = Env.load("hyper-evm");
        assertEq(config.network.centrifugeId, 9);
        config.network.buildBatchLimits();
    }

    function test_parseOptimism() public view {
        EnvConfig memory config = Env.load("optimism");
        assertEq(config.network.centrifugeId, 10);
        config.network.buildBatchLimits();
    }

    function test_parseMonad() public view {
        EnvConfig memory config = Env.load("monad");
        assertEq(config.network.centrifugeId, 11);
        config.network.buildBatchLimits();
    }
}

contract EnvTestnetFilesTest is Test {
    function test_parseSepolia() public view {
        EnvConfig memory config = Env.load("sepolia");
        assertEq(config.network.centrifugeId, 1);
        config.network.buildBatchLimits();
    }

    function test_parseBaseSepolia() public view {
        EnvConfig memory config = Env.load("base-sepolia");
        assertEq(config.network.centrifugeId, 2);
        config.network.buildBatchLimits();
    }

    function test_parseArbitrumSepolia() public view {
        EnvConfig memory config = Env.load("arbitrum-sepolia");
        assertEq(config.network.centrifugeId, 3);
        config.network.buildBatchLimits();
    }

    function test_parseHyperEvmTestnet() public view {
        EnvConfig memory config = Env.load("hyper-evm-testnet");
        assertEq(config.network.centrifugeId, 9);
        config.network.buildBatchLimits();
    }
}
