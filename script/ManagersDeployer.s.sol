// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {VaultDecoder} from "src/managers/decoders/VaultDecoder.sol";
import {CircleDecoder} from "src/managers/decoders/CircleDecoder.sol";
import {OnOfframpManagerFactory} from "src/managers/OnOfframpManager.sol";
import {MerkleProofManagerFactory} from "src/managers/MerkleProofManager.sol";

import {CommonInput} from "script/CommonDeployer.s.sol";
import {SpokeDeployer, SpokeCBD} from "script/SpokeDeployer.s.sol";

import "forge-std/Script.sol";
import {ICreateX} from "createx-forge/script/ICreateX.sol";

contract ManagersCBD is SpokeCBD {
    OnOfframpManagerFactory public onOfframpManagerFactory;
    MerkleProofManagerFactory public merkleProofManagerFactory;
    VaultDecoder public vaultDecoder;
    CircleDecoder public circleDecoder;

    function deployManagers(CommonInput memory input, ICreateX createX, address deployer) public {
        deploySpoke(input, createX, deployer);

        onOfframpManagerFactory = OnOfframpManagerFactory(
            createX.deployCreate3(
                generateSalt("onOfframpManagerFactory"),
                abi.encodePacked(type(OnOfframpManagerFactory).creationCode, abi.encode(spoke, balanceSheet))
            )
        );

        merkleProofManagerFactory = MerkleProofManagerFactory(
            createX.deployCreate3(
                generateSalt("merkleProofManagerFactory"),
                abi.encodePacked(type(MerkleProofManagerFactory).creationCode, abi.encode(spoke))
            )
        );

        vaultDecoder = VaultDecoder(
            createX.deployCreate3(generateSalt("vaultDecoder"), abi.encodePacked(type(VaultDecoder).creationCode))
        );

        circleDecoder = CircleDecoder(
            createX.deployCreate3(generateSalt("circleDecoder"), abi.encodePacked(type(CircleDecoder).creationCode))
        );
    }

    function removeManagersDeployerAccess(address deployer) public {
        removeSpokeDeployerAccess(deployer);
    }
}

contract ManagersDeployer is SpokeDeployer, ManagersCBD {
    function deployManagers(CommonInput memory input, address deployer) public {
        super.deployManagers(input, _createX(), deployer);
    }

    function managersRegister() internal {
        spokeRegister();
        register("onOfframpManagerFactory", address(onOfframpManagerFactory));
        register("merkleProofManagerFactory", address(merkleProofManagerFactory));
        register("vaultDecoder", address(vaultDecoder));
        register("circleDecoder", address(circleDecoder));
    }
}
