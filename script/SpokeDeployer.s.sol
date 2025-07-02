// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";

import {CommonDeployer, CommonInput, CommonReport, CommonActionBatcher} from "script/CommonDeployer.s.sol";

import "forge-std/Script.sol";

struct SpokeReport {
    CommonReport common;
    Spoke spoke;
    BalanceSheet balanceSheet;
    TokenFactory tokenFactory;
}

contract SpokeActionBatcher is CommonActionBatcher {
    function engageSpoke(SpokeReport memory report, bool newRoot) public unlocked {
        // Rely Spoke
        report.tokenFactory.rely(address(report.spoke));
        report.common.messageDispatcher.rely(address(report.spoke));
        report.common.poolEscrowFactory.rely(address(report.spoke));
        report.common.gateway.rely(address(report.spoke));

        // Rely BalanceSheet
        report.common.messageDispatcher.rely(address(report.balanceSheet));
        report.common.gateway.rely(address(report.balanceSheet));

        // Rely Root
        report.spoke.rely(address(report.common.root));
        report.balanceSheet.rely(address(report.common.root));
        report.tokenFactory.rely(address(report.common.root));

        // Rely messageProcessor
        report.spoke.rely(address(report.common.messageProcessor));
        report.balanceSheet.rely(address(report.common.messageProcessor));

        // Rely messageDispatcher
        report.spoke.rely(address(report.common.messageDispatcher));
        report.balanceSheet.rely(address(report.common.messageDispatcher));

        // File methods
        report.common.messageDispatcher.file("spoke", address(report.spoke));
        report.common.messageDispatcher.file("balanceSheet", address(report.balanceSheet));

        report.common.messageProcessor.file("spoke", address(report.spoke));
        report.common.messageProcessor.file("balanceSheet", address(report.balanceSheet));

        report.spoke.file("gateway", address(report.common.gateway));
        report.spoke.file("sender", address(report.common.messageDispatcher));
        report.spoke.file("poolEscrowFactory", address(report.common.poolEscrowFactory));

        report.balanceSheet.file("spoke", address(report.spoke));
        report.balanceSheet.file("sender", address(report.common.messageDispatcher));
        report.balanceSheet.file("gateway", address(report.common.gateway));
        report.balanceSheet.file("poolEscrowProvider", address(report.common.poolEscrowFactory));

        report.common.poolEscrowFactory.file("balanceSheet", address(report.balanceSheet));

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(report.spoke);
        tokenWards[1] = address(report.balanceSheet);

        report.tokenFactory.file("wards", tokenWards);

        // Endorse methods
        if (newRoot) {
            report.common.root.endorse(address(report.balanceSheet));
        }
    }

    function revokeSpoke(SpokeReport memory report) public unlocked {
        report.tokenFactory.deny(address(this));
        report.spoke.deny(address(this));
        report.balanceSheet.deny(address(this));
    }
}

contract SpokeDeployer is CommonDeployer {
    Spoke public spoke;
    BalanceSheet public balanceSheet;
    TokenFactory public tokenFactory;

    function deploySpoke(CommonInput memory input, SpokeActionBatcher batcher) public {
        _preDeploySpoke(input, batcher);
        _postDeploySpoke(batcher);
    }

    function _preDeploySpoke(CommonInput memory input, SpokeActionBatcher batcher) internal {
        if (address(spoke) != address(0)) {
            return; // Already deployed. Make this method idempotent.
        }

        _preDeployCommon(input, batcher);

        tokenFactory = TokenFactory(
            create3(
                generateSalt("tokenFactory"),
                abi.encodePacked(type(TokenFactory).creationCode, abi.encode(address(root), batcher))
            )
        );

        spoke = Spoke(
            create3(
                generateSalt("spoke"), abi.encodePacked(type(Spoke).creationCode, abi.encode(tokenFactory, batcher))
            )
        );

        balanceSheet = BalanceSheet(
            create3(
                generateSalt("balanceSheet"),
                abi.encodePacked(type(BalanceSheet).creationCode, abi.encode(root, batcher))
            )
        );

        batcher.engageSpoke(_spokeReport(), newRoot);

        register("tokenFactory", address(tokenFactory));
        register("spoke", address(spoke));
        register("balanceSheet", address(balanceSheet));
    }

    function _postDeploySpoke(SpokeActionBatcher batcher) internal {
        _postDeployCommon(batcher);
    }

    function removeSpokeDeployerAccess(SpokeActionBatcher batcher) public {
        if (spoke.wards(address(batcher)) == 0) {
            return; // Already removed. Make this method idempotent.
        }

        removeCommonDeployerAccess(batcher);

        batcher.revokeSpoke(_spokeReport());
    }

    function _spokeReport() internal view returns (SpokeReport memory) {
        return SpokeReport(_commonReport(), spoke, balanceSheet, tokenFactory);
    }
}
