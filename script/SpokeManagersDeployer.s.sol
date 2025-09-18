// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {SpokeDeployer, SpokeReport, SpokeActionBatcher} from "./SpokeDeployer.s.sol";

import {VaultDecoder} from "../src/managers/spoke/decoders/VaultDecoder.sol";
import {CircleDecoder} from "../src/managers/spoke/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "../src/managers/spoke/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "../src/managers/spoke/MerkleProofManager.sol";

import "forge-std/Script.sol";

struct SpokeManagersReport {
    SpokeReport spoke;
    OnOfframpManagerFactory onOfframpManagerFactory;
    MerkleProofManagerFactory merkleProofManagerFactory;
    VaultDecoder vaultDecoder;
    CircleDecoder circleDecoder;
}

contract SpokeManagersActionBatcher is SpokeActionBatcher {}

contract SpokeManagersDeployer is SpokeDeployer {
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

    function _postDeploySpokeManagers(SpokeManagersActionBatcher batcher) internal {
        _postDeploySpoke(batcher);
    }

    function removeSpokeManagersDeployerAccess(SpokeManagersActionBatcher batcher) public {
        removeSpokeDeployerAccess(batcher);
    }

    function _spokeManagersReport() internal view returns (SpokeManagersReport memory) {
        return SpokeManagersReport(
            _spokeReport(), onOfframpManagerFactory, merkleProofManagerFactory, vaultDecoder, circleDecoder
        );
    }
}
