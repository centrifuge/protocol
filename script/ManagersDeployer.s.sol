// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultDecoder} from "src/managers/decoders/VaultDecoder.sol";
import {CircleDecoder} from "src/managers/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "src/managers/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "src/managers/MerkleProofManager.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";

contract ManagersDeployer is SpokeDeployer {
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    function deployManagers(CommonInput memory input, address deployer) public {
        deploySpoke(input, deployer);

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

        _managersRegister();
    }

    function _managersRegister() private {
        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));
    }

    function removeManagersDeployerAccess(address deployer) public {
        removeSpokeDeployerAccess(deployer);
    }
}
