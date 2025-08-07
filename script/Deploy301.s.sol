// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AsyncRequestManager} from "../src/vaults/AsyncRequestManager.sol";
import {AsyncVaultFactory} from "../src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "../src/vaults/factories/SyncDepositVaultFactory.sol";

import {Create2VaultFactorySpellEthereum} from "../test/spell/Create2VaultFactorySpellEthereum.sol";

import {CreateXScript} from "createx-forge/script/CreateXScript.sol";

import "forge-std/Script.sol";

contract Deploy301 is Script, CreateXScript {
    address root = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address asyncRequestManager = 0xf06f89A1b6C601235729A689595571B7455Dd433;
    address globalEscrow = 0x43d51be0B6dE2199A2396bA604114d24383F91E9;
    address syncManager = 0x0D82d9fa76CFCd6F4cc59F053b2458665C6CE773;

    bytes32 version;

    /**
     * @dev Generates a salt for contract deployment
     * @param contractName The name of the contract
     * @return salt A deterministic salt based on contract name and optional VERSION
     */
    function generateSalt(string memory contractName) internal view returns (bytes32) {
        if (version != bytes32(0)) {
            return keccak256(abi.encodePacked(contractName, version));
        }
        return keccak256(abi.encodePacked(contractName));
    }

    function run() public {
        vm.startBroadcast();

        version = keccak256("3");

        setUpCreateXFactory();

        AsyncVaultFactory asyncVaultFactory = AsyncVaultFactory(
            create3(
                generateSalt("asyncVaultFactory-2"),
                abi.encodePacked(
                    type(AsyncVaultFactory).creationCode, abi.encode(address(root), asyncRequestManager, root)
                )
            )
        );

        SyncDepositVaultFactory syncDepositVaultFactory = SyncDepositVaultFactory(
            create3(
                generateSalt("syncDepositVaultFactory-2"),
                abi.encodePacked(
                    type(SyncDepositVaultFactory).creationCode,
                    abi.encode(address(root), syncManager, asyncRequestManager, root)
                )
            )
        );

        require(address(asyncVaultFactory) == 0xed9D489BB79c7CB58c522f36Fc6944eAA95Ce385); // TODO
        require(address(syncDepositVaultFactory) == 0x21BF2544b5A0B03c8566a16592ba1b3B192B50Bc); // TODO

        create3(
            generateSalt("spell-004"),
            abi.encodePacked(
                type(Create2VaultFactorySpellEthereum).creationCode, abi.encode(address(asyncVaultFactory), address(syncDepositVaultFactory))
            )
        );

        vm.stopBroadcast();
    }
}