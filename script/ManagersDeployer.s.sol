// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultDecoder} from "src/managers/decoders/VaultDecoder.sol";
import {CircleDecoder} from "src/managers/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "src/managers/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "src/managers/MerkleProofManager.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";

struct ManagersReport {
    SpokeReport spoke;
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
}

contract ManagersActionBatcher is SpokeActionBatcher {}

contract ManagersDeployer is SpokeDeployer {
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    function deployManagers(CommonInput memory input, ManagersActionBatcher batcher) public {
        preDeployManagers(input, batcher);
        postDeployManagers(batcher);
    }

    function preDeployManagers(CommonInput memory input, ManagersActionBatcher batcher) internal {
        preDeploySpoke(input, batcher);

        onOfframpManagerFactory = OnOfframpManagerFactory(
            create3(
                generateSalt("onOfframpManagerFactory"),
                abi.encodePacked(type(OnOfframpManagerFactory).creationCode, abi.encode(spoke, balanceSheet))
            )
        );

        merkleProofManagerFactory = MerkleProofManagerFactory(
            create3(
                generateSalt("merkleProofManagerFactory"),
                abi.encodePacked(type(MerkleProofManagerFactory).creationCode, abi.encode(spoke))
            )
        );

        vaultDecoder =
            VaultDecoder(create3(generateSalt("vaultDecoder"), abi.encodePacked(type(VaultDecoder).creationCode)));

        circleDecoder =
            CircleDecoder(create3(generateSalt("circleDecoder"), abi.encodePacked(type(CircleDecoder).creationCode)));

        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));
    }

    function postDeployManagers(ManagersActionBatcher batcher) internal {
        postDeploySpoke(batcher);
    }

    function removeManagersDeployerAccess(ManagersActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);
    }

    function _managersReport() internal view returns (ManagersReport memory) {
        return ManagersReport(
            _spokeReport(), onOfframpManagerFactory, merkleProofManagerFactory, vaultDecoder, circleDecoder
        );
    }
}
