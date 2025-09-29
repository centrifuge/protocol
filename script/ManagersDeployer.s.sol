// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {QueueManager} from "../src/managers/QueueManager.sol";
import {VaultDecoder} from "../src/managers/decoders/VaultDecoder.sol";
import {CircleDecoder} from "../src/managers/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../src/managers/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../src/managers/MerkleProofManager.sol";

struct ManagersReport {
    SpokeReport spoke;
    QueueManager queueManager;
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
}

contract ManagersActionBatcher is SpokeActionBatcher {
    function engageManagers(ManagersReport memory report) public onlyDeployer {
        // rely QueueManager on Gateway
        report.spoke.common.gateway.rely(address(report.queueManager));

        // rely Root
        report.queueManager.rely(address(report.spoke.common.root));

        // rely crosschainBatcher
        report.queueManager.rely(address(report.spoke.common.crosschainBatcher));
    }

    function revokeManagers(ManagersReport memory report) public onlyDeployer {
        report.queueManager.deny(address(this));
    }
}

contract ManagersDeployer is SpokeDeployer {
    QueueManager public queueManager;
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    function deployManagers(CommonInput memory input, ManagersActionBatcher batcher) public {
        _preDeployManagers(input, batcher);
        _postDeployManagers(batcher);
    }

    function _preDeployManagers(CommonInput memory input, ManagersActionBatcher batcher) internal {
        _preDeploySpoke(input, batcher);

        queueManager = QueueManager(
            create3(
                generateSalt("queueManager"),
                abi.encodePacked(
                    type(QueueManager).creationCode,
                    abi.encode(contractUpdater, balanceSheet, crosschainBatcher, address(batcher))
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

        batcher.engageManagers(_managersReport());

        register("queueManager", address(queueManager));
        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));
    }

    function _postDeployManagers(ManagersActionBatcher batcher) internal {
        _postDeploySpoke(batcher);
    }

    function removeManagersDeployerAccess(ManagersActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);

        batcher.revokeManagers(_managersReport());
    }

    function _managersReport() internal view returns (ManagersReport memory) {
        return ManagersReport(
            _spokeReport(),
            queueManager,
            onOfframpManagerFactory,
            merkleProofManagerFactory,
            vaultDecoder,
            circleDecoder
        );
    }
}
