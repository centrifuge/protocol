// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EnvConfig, Env, Connection} from "../../script/utils/EnvConfig.s.sol";

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

    function test_parsePharos() public view {
        EnvConfig memory config = Env.load("pharos");
        assertEq(config.network.centrifugeId, 12);
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

contract EnvConnectionsTest is Test {
    function test_mainnetConnectionsRequireDeployedAdapters() public view {
        _validateConnectionsHasDeployedAdapters("mainnet");
    }

    function test_testnetConnectionsRequireDeployedAdapters() public view {
        _validateConnectionsHasDeployedAdapters("testnet");
    }

    function _validateConnectionsHasDeployedAdapters(string memory environment) private view {
        string memory json = vm.readFile(string.concat("env/connections/", environment, ".json"));
        string[] memory networks = vm.parseJsonStringArray(json, ".networks");

        for (uint256 i; i < networks.length; i++) {
            string memory networkName = networks[i];
            EnvConfig memory chain1 = Env.load(networkName);
            Connection[] memory connections = chain1.network.connections;

            for (uint256 j; j < connections.length; j++) {
                EnvConfig memory chain2 = Env.load(connections[j].network);
                string memory pair = string.concat(networkName, " <-> ", connections[j].network);

                if (connections[j].layerZero) {
                    assertTrue(chain1.adapters.layerZero.deploy, _err(pair, "layerZero"));
                    assertTrue(chain2.adapters.layerZero.deploy, _err(pair, "layerZero"));
                }
                if (connections[j].wormhole) {
                    assertTrue(chain1.adapters.wormhole.deploy, _err(pair, "wormhole"));
                    assertTrue(chain2.adapters.wormhole.deploy, _err(pair, "wormhole"));
                }
                if (connections[j].axelar) {
                    assertTrue(chain1.adapters.axelar.deploy, _err(pair, "axelar"));
                    assertTrue(chain2.adapters.axelar.deploy, _err(pair, "axelar"));
                }
                if (connections[j].chainlink) {
                    assertTrue(chain1.adapters.layerZero.deploy, _err(pair, "layerZero"));
                    assertTrue(chain2.adapters.layerZero.deploy, _err(pair, "layerZero"));
                }
            }
        }
    }

    function _err(string memory pair, string memory adapter) private pure returns (string memory) {
        return string.concat(pair, ": ", adapter, " not deployed in one of the chains");
    }
}

