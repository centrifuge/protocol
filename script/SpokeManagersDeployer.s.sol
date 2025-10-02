// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {QueueManager} from "../src/managers/spoke/QueueManager.sol";
import {VaultDecoder} from "../src/managers/spoke/decoders/VaultDecoder.sol";
import {CircleDecoder} from "../src/managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../src/managers/spoke/MerkleProofManager.sol";

struct SpokeManagersReport {
    SpokeReport spoke;
    QueueManager queueManager;
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
}

contract SpokeManagersActionBatcher is SpokeActionBatcher {
    function engageManagers(SpokeManagersReport memory report) public onlyDeployer {
        // rely QueueManager on Gateway
        report.spoke.common.gateway.rely(address(report.queueManager));

        // rely Root
        report.queueManager.rely(address(report.spoke.common.root));
    }

    function revokeManagers(SpokeManagersReport memory report) public onlyDeployer {
        report.queueManager.deny(address(this));
    }
}

contract SpokeManagersDeployer is SpokeDeployer {
    QueueManager public queueManager;
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    function deploySpokeManagers(CommonInput memory input, SpokeManagersActionBatcher batcher) public {
        _preDeploySpokeManagers(input, batcher);
        _postDeploySpokeManagers(batcher);
    }

    function _preDeploySpokeManagers(CommonInput memory input, SpokeManagersActionBatcher batcher) internal {
        _preDeploySpoke(input, batcher);

        queueManager = QueueManager(
            create3(
                generateSalt("queueManager"),
                abi.encodePacked(
                    type(QueueManager).creationCode, abi.encode(contractUpdater, balanceSheet, address(batcher))
                )
            )
        );

        onOfframpManagerFactory = OnOfframpManagerFactory(
            create3(
                generateSalt("onOfframpManagerFactory"),
                abi.encodePacked(type(OnOfframpManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet))
            )
        );

        merkleProofManagerFactory = MerkleProofManagerFactory(
            create3(
                generateSalt("merkleProofManagerFactory"),
                abi.encodePacked(
                    type(MerkleProofManagerFactory).creationCode, abi.encode(contractUpdater, balanceSheet)
                )
            )
        );

        vaultDecoder =
            VaultDecoder(create3(generateSalt("vaultDecoder"), abi.encodePacked(type(VaultDecoder).creationCode)));

        circleDecoder =
            CircleDecoder(create3(generateSalt("circleDecoder"), abi.encodePacked(type(CircleDecoder).creationCode)));

        batcher.engageManagers(_spokeManagersReport());

        register("queueManager", address(queueManager));
        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));
    }

    function _postDeploySpokeManagers(SpokeManagersActionBatcher batcher) internal {
        _postDeploySpoke(batcher);
    }

    function removeSpokeManagersDeployerAccess(SpokeManagersActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);

        batcher.revokeManagers(_spokeManagersReport());
    }

    function _spokeManagersReport() internal view returns (SpokeManagersReport memory) {
        return SpokeManagersReport(
            _spokeReport(),
            queueManager,
            onOfframpManagerFactory,
            merkleProofManagerFactory,
            vaultDecoder,
            circleDecoder
        );
    }
}
