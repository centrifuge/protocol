// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";

import "forge-std/Test.sol";

/// @title EnvConfigDvnParsingTest
/// @notice Unit-level coverage of the 4-of-5 DVN schema: confirms `env/<chain>.json` parses into the new
///         split `requiredDVNs`/`optionalDVNs`/`optionalDVNThreshold` fields, and that ascending-sort and
///         threshold invariants hold across all 10 mainnet chains + 4 testnet chains.
/// @dev    This test does NOT require an RPC fork, it just reads and parses env JSON files from disk.
///         The LayerZero metadata API (https://metadata.layerzero-api.com/v1/metadata/dvns) is the
///         off-chain source of truth for DVN addresses; that cross-check is handled by
///         `script/utils/fetch-dvn-addresses.js`, not duplicated here as a snapshot.
contract EnvConfigDvnParsingTest is Test {
    // Mainnet 4-of-5 shape: 2 required + 2-of-3 optional.
    uint256 internal constant MAINNET_REQUIRED = 2;
    uint256 internal constant MAINNET_OPTIONAL = 3;
    uint8 internal constant MAINNET_THRESHOLD = 2;

    // Testnet shape: single required, no optional.
    uint256 internal constant TESTNET_REQUIRED = 1;
    uint256 internal constant TESTNET_OPTIONAL = 0;
    uint8 internal constant TESTNET_THRESHOLD = 0;

    function _assertSortedAscending(address[] memory xs, string memory label) internal pure {
        for (uint256 i = 1; i < xs.length; i++) {
            require(xs[i - 1] < xs[i], string.concat(label, ": must be sorted ascending"));
        }
    }

    function _assertChain(
        string memory name,
        uint256 expectedRequired,
        uint256 expectedOptional,
        uint8 expectedThreshold
    ) internal view {
        EnvConfig memory config = Env.load(name);
        assertEq(
            config.adapters.layerZero.requiredDVNs.length,
            expectedRequired,
            string.concat(name, ": requiredDVNs.length")
        );
        assertEq(
            config.adapters.layerZero.optionalDVNs.length,
            expectedOptional,
            string.concat(name, ": optionalDVNs.length")
        );
        assertEq(
            config.adapters.layerZero.optionalDVNThreshold,
            expectedThreshold,
            string.concat(name, ": optionalDVNThreshold")
        );
        _assertSortedAscending(config.adapters.layerZero.requiredDVNs, string.concat(name, ": requiredDVNs"));
        _assertSortedAscending(config.adapters.layerZero.optionalDVNs, string.concat(name, ": optionalDVNs"));
    }

    // --- Mainnet shape coverage (10 chains, 4-of-5 each) ---

    function test_Mainnet_Ethereum() external view {
        _assertChain("ethereum", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Base() external view {
        _assertChain("base", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Arbitrum() external view {
        _assertChain("arbitrum", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Optimism() external view {
        _assertChain("optimism", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Avalanche() external view {
        _assertChain("avalanche", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_BnbSmartChain() external view {
        _assertChain("bnb-smart-chain", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Plume() external view {
        _assertChain("plume", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_HyperEvm() external view {
        _assertChain("hyper-evm", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Monad() external view {
        _assertChain("monad", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    function test_Mainnet_Pharos() external view {
        _assertChain("pharos", MAINNET_REQUIRED, MAINNET_OPTIONAL, MAINNET_THRESHOLD);
    }

    // --- Testnet shape coverage ---

    function test_Testnet_Sepolia() external view {
        _assertChain("sepolia", TESTNET_REQUIRED, TESTNET_OPTIONAL, TESTNET_THRESHOLD);
    }

    function test_Testnet_BaseSepolia() external view {
        _assertChain("base-sepolia", TESTNET_REQUIRED, TESTNET_OPTIONAL, TESTNET_THRESHOLD);
    }

    function test_Testnet_ArbitrumSepolia() external view {
        _assertChain("arbitrum-sepolia", TESTNET_REQUIRED, TESTNET_OPTIONAL, TESTNET_THRESHOLD);
    }

    function test_Testnet_HyperEvmTestnet() external view {
        _assertChain("hyper-evm-testnet", TESTNET_REQUIRED, TESTNET_OPTIONAL, TESTNET_THRESHOLD);
    }
}
