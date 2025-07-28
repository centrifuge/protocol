// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {VaultDecoder} from "../src/managers/decoders/VaultDecoder.sol";
import {CircleDecoder} from "../src/managers/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../src/managers/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../src/managers/MerkleProofManager.sol";

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
        _preDeployManagers(input, batcher);
        _postDeployManagers(batcher);
    }

    function _preDeployManagers(CommonInput memory input, ManagersActionBatcher batcher) internal {
        _preDeploySpoke(input, batcher);

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
    }

    function _managersReport() internal view returns (ManagersReport memory) {
        return ManagersReport(
            _spokeReport(), onOfframpManagerFactory, merkleProofManagerFactory, vaultDecoder, circleDecoder
        );
    }
}
