// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Env, EnvConfig} from "../../../script/utils/EnvConfig.s.sol";
import {GraphQLQuery} from "../../../script/utils/GraphQLQuery.s.sol";

import {FlowRegression} from "../spell/utils/FlowRegression.sol";
import {NonCoreReport} from "../../../src/deployment/ActionBatchers.sol";
import {testContractsFromConfig} from "../spell/utils/validation/TestContracts.sol";
import {
    InvestmentFlowExecutor,
    InvestmentFlowResult,
    VaultGraphQLData
} from "../spell/utils/validation/InvestmentFlowExecutor.sol";

/// @title InvestmentFlowForkTest
/// @notice Fork test that runs end-to-end deposit and redeem flows on all live vaults per network.
///         Queries vault metadata from the GraphQL indexer (via the shared FlowRegression mixin) and
///         delegates flow execution to InvestmentFlowExecutor, which handles local async, cross-chain
///         async, and sync deposit flows.
contract InvestmentFlowForkTest is FlowRegression {
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

    function testInvestmentFlows() external {
        _testCase(vm.envString("NETWORK"));
    }
}
