// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {JsonUtils} from "../../../script/utils/JsonUtils.s.sol";
import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../script/utils/GraphQLQuery.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {NonCoreReport} from "../../../src/deployment/ActionBatchers.sol";
import {testContractsFromConfig} from "../spell/utils/validation/TestContracts.sol";
import {
    InvestmentFlowExecutor,
    InvestmentFlowResult,
    VaultGraphQLData
} from "../spell/utils/validation/InvestmentFlowExecutor.sol";

/// @title InvestmentFlowForkTest
/// @notice Fork test that runs end-to-end deposit and redeem flows on all live vaults per network.
///         Queries vault metadata from the GraphQL indexer and delegates flow execution to
///         InvestmentFlowExecutor, which handles local async, cross-chain async, and sync deposit flows.
contract InvestmentFlowForkTest is Test {
    using stdJson for string;
    using JsonUtils for *;

    // ============================================
    // Entry Point
    // ============================================

    function _testCase(string memory networkName) internal {
        EnvConfig memory config = Env.load(networkName);
        vm.createSelectFork(config.network.rpcUrl());

        NonCoreReport memory report = testContractsFromConfig(config).main;

        GraphQLQuery indexer = new GraphQLQuery(config.network.graphQLApi());
        VaultGraphQLData[] memory vaults = _queryVaults(indexer, config.network.centrifugeId);

        if (vaults.length == 0) return;

        InvestmentFlowExecutor executor = new InvestmentFlowExecutor();
        vm.deal(address(executor), 100 ether);

        InvestmentFlowResult[] memory results = executor.executeAllFlows(report, vaults, config.network.centrifugeId);

        _assertResults(results);
    }

    // ============================================
    // GraphQL Vault Query
    // ============================================

    function _queryVaults(GraphQLQuery indexer, uint16 centrifugeId)
        internal
        returns (VaultGraphQLData[] memory vaults)
    {
        string memory centrifugeIdStr = vm.toString(centrifugeId).asJsonString();

        string memory json = indexer.queryGraphQL(
            string.concat(
                "vaults(limit: 1000, where: { centrifugeId: ",
                centrifugeIdStr,
                ", status: Linked }) { totalCount items { id poolId tokenId kind assetAddress asset { decimals symbol } token { pool { managers(where: {isHubManager: true}, limit: 1) { items { address centrifugeId } } } } } }"
            )
        );

        uint256 totalCount = json.readUint(".data.vaults.totalCount");
        if (totalCount == 0) return vaults;

        require(totalCount <= 1000, "Vault count exceeds query limit; implement pagination");

        vaults = new VaultGraphQLData[](totalCount);

        for (uint256 i; i < totalCount; i++) {
            string memory base = ".data.vaults.items";
            vaults[i].vault = json.readAddress(base.asJsonPath(i, "id"));
            vaults[i].poolIdRaw = uint64(json.readUint(base.asJsonPath(i, "poolId")));
            vaults[i].tokenIdRaw = _parseBytes16(json, base.asJsonPath(i, "tokenId"));
            vaults[i].kind = json.readString(base.asJsonPath(i, "kind"));
            vaults[i].assetAddress = json.readAddress(base.asJsonPath(i, "assetAddress"));
            vaults[i].assetDecimals = uint8(json.readUint(base.asJsonPath(i, "asset.decimals")));
            vaults[i].assetSymbol = json.readString(base.asJsonPath(i, "asset.symbol"));

            string memory managersBase = string.concat(base, "[", vm.toString(i), "].token.pool.managers.items");
            try vm.parseJsonAddress(json, string.concat(managersBase, "[0].address")) returns (address mgr) {
                vaults[i].hubManager = mgr;
            } catch {}
            try vm.parseJsonUint(json, string.concat(managersBase, "[0].centrifugeId")) returns (uint256 cid) {
                vaults[i].hubCentrifugeId = uint16(cid);
            } catch {}
        }
    }

    function _parseBytes16(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        assembly {
            result := mload(add(rawBytes, 32))
        }
    }

    // ============================================
    // Result Assertion
    // ============================================

    function _assertResults(InvestmentFlowResult[] memory results) internal {
        uint256 depositFailures;
        uint256 redeemFailures;

        for (uint256 i; i < results.length; i++) {
            if (!results[i].depositPassed) {
                emit log_string(string.concat(
                        "Deposit FAILED for vault ", vm.toString(results[i].vault), ": ", results[i].depositError
                    ));
                depositFailures++;
            }
            if (!results[i].redeemPassed) {
                emit log_string(string.concat(
                        "Redeem FAILED for vault ", vm.toString(results[i].vault), ": ", results[i].redeemError
                    ));
                redeemFailures++;
            }
        }

        assertEq(depositFailures, 0, "Some deposit flows failed");
        assertEq(redeemFailures, 0, "Some redeem flows failed");
    }

    // ============================================
    // Per-Network Test Functions
    // ============================================

    function testInvestmentFlows_Ethereum() external {
        _testCase("ethereum");
    }

    function testInvestmentFlows_Base() external {
        _testCase("base");
    }

    function testInvestmentFlows_Arbitrum() external {
        _testCase("arbitrum");
    }

    function testInvestmentFlows_Plume() external {
        _testCase("plume");
    }

    function testInvestmentFlows_Avalanche() external {
        _testCase("avalanche");
    }

    function testInvestmentFlows_BnbSmartChain() external {
        _testCase("bnb-smart-chain");
    }

    function testInvestmentFlows_Optimism() external {
        _testCase("optimism");
    }

    function testInvestmentFlows_HyperEvm() external {
        _testCase("hyper-evm");
    }

    function testInvestmentFlows_Monad() external {
        _testCase("monad");
    }
}
