// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {testContractsFromConfig} from "./validation/TestContracts.sol";
import {InvestmentFlowExecutor, InvestmentFlowResult, VaultGraphQLData} from "./validation/InvestmentFlowExecutor.sol";

import {EnvConfig} from "../../../../script/utils/EnvConfig.s.sol";
import {JsonUtils} from "../../../../script/utils/JsonUtils.s.sol";
import {GraphQLQuery} from "../../../../script/utils/GraphQLQuery.s.sol";

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {NonCoreReport} from "../../../../src/deployment/ActionBatchers.sol";

/// @title  FlowRegression
/// @notice Reusable investment-flow regression mixin for spell fork tests.
///         Investment-flow regression is a per-vault end-to-end behavioral diff
///         (deposit/redeem), not a state invariant, so it is NOT a
///         `BaseValidator`. This mixin owns the cheatcode-driven snapshot run,
///         the GraphQL vault query (single source of truth, also inherited by
///         `InvestmentFlowForkTest`), and the pre/post regression diff.
///
/// @dev    A "regression" is a vault that passed BEFORE the spell and fails
///         AFTER it. Pre-existing failures (the live env has known broken
///         vaults) are logged but tolerated — only regressions hard-fail.
///         Implemented as an inherited mixin (internal functions, no ABI
///         boundary); see `validation/README.md`, "Legacy-codegen constraints".
abstract contract FlowRegression is Test {
    using stdJson for string;
    using JsonUtils for *;

    function _snapshotFlows(EnvConfig memory config, VaultGraphQLData[] memory vaults)
        internal
        returns (InvestmentFlowResult[] memory)
    {
        if (vaults.length == 0) return new InvestmentFlowResult[](0);

        uint256 snap = vm.snapshotState();

        NonCoreReport memory report = testContractsFromConfig(config).main;
        InvestmentFlowExecutor executor = new InvestmentFlowExecutor();
        vm.deal(address(executor), 100 ether);

        InvestmentFlowResult[] memory results = executor.executeAllFlows(report, vaults, config.network.centrifugeId);

        vm.revertToState(snap);

        return results;
    }

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
                try vm.parseJsonUint(json, string.concat(managersBase, "[0].centrifugeId")) returns (uint256 cid) {
                    vaults[i].hubCentrifugeId = uint16(cid);
                } catch {
                    // Anomalous: indexer lists a hub manager but no parseable centrifugeId.
                    emit log_string(string.concat(
                            "WARN: hub manager without parseable centrifugeId for vault ", vm.toString(vaults[i].vault)
                        ));
                }
            } catch {
                // Expected absence: pool has no hub manager registered in the
                // indexer (managers query returned no items) — leave both fields zero.
            }
        }
    }

    /// @dev Pre and post arrays index identically because both runs were
    ///      given the same `vaults[]` (`executeAllFlows` writes results in
    ///      input order).
    function _assertNoFlowRegressions(InvestmentFlowResult[] memory pre, InvestmentFlowResult[] memory post) internal {
        assertEq(pre.length, post.length, "Pre/post flow result length mismatch");

        uint256 depositRegressions;
        uint256 redeemRegressions;

        emit log_string("");
        emit log_string("================================================================");
        emit log_string("     INVESTMENT FLOW DIFF (pre-cast vs post-cast)");
        emit log_string("================================================================");

        for (uint256 i = 0; i < post.length; i++) {
            InvestmentFlowResult memory b = pre[i];
            InvestmentFlowResult memory a = post[i];

            if (b.depositPassed && !a.depositPassed) {
                emit log_string(string.concat("[REGRESSION deposit] ", vm.toString(a.vault), " -> ", a.depositError));
                depositRegressions++;
            } else if (!b.depositPassed && a.depositPassed) {
                emit log_string(string.concat("[IMPROVED deposit]   ", vm.toString(a.vault)));
            } else if (!b.depositPassed && !a.depositPassed) {
                emit log_string(string.concat("[PRE-EXISTING deposit] ", vm.toString(a.vault), " -> ", a.depositError));
            }

            if (b.redeemPassed && !a.redeemPassed) {
                emit log_string(string.concat("[REGRESSION redeem]  ", vm.toString(a.vault), " -> ", a.redeemError));
                redeemRegressions++;
            } else if (!b.redeemPassed && a.redeemPassed) {
                emit log_string(string.concat("[IMPROVED redeem]    ", vm.toString(a.vault)));
            } else if (!b.redeemPassed && !a.redeemPassed) {
                emit log_string(string.concat("[PRE-EXISTING redeem]  ", vm.toString(a.vault), " -> ", a.redeemError));
            }
        }

        emit log_string("================================================================");

        assertEq(depositRegressions, 0, "Spell regressed deposit flows on previously-passing vaults");
        assertEq(redeemRegressions, 0, "Spell regressed redeem flows on previously-passing vaults");
    }

    /// @dev Loop variant (no inline assembly), preferred under optimizer_runs=1
    ///      legacy codegen. Equivalence with the original assembly `mload`
    ///      variant is pinned by `FlowRegression.t.sol`.
    function _parseBytes16(string memory json, string memory path) internal pure returns (bytes16 result) {
        bytes memory rawBytes = json.readBytes(path);
        require(rawBytes.length == 16, "Expected 16 bytes for tokenId");
        for (uint256 i = 0; i < 16; i++) {
            result |= bytes16(rawBytes[i]) >> (i * 8);
        }
    }
}
