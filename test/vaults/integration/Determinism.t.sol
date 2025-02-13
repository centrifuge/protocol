// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.26;

// import {Root} from "src/Root.sol";
// import {RestrictionManager} from "src/token/RestrictionManager.sol";
// import {Escrow} from "src/Escrow.sol";
// import {TrancheFactory} from "src/factories/TrancheFactory.sol";
// import {TransferProxyFactory} from "src/factories/TransferProxyFactory.sol";
// import "forge-std/Test.sol";

// contract DeterminismTest is Test {
//     address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
//     address constant MAINNET_DEPLOYER = 0x7270b20603FbB3dF0921381670fbd62b9991aDa4;
//     bytes32 constant MAINNET_SALT = 0x7270b20603fbb3df0921381670fbd62b9991ada4b17953a73f70fdff36730018;
//     uint256 internal constant DELAY = 48 hours;

//     function testNewDeploymentDeterminism() public {
//         address escrow =
//             _deploy(MAINNET_SALT, abi.encodePacked(type(Escrow).creationCode,
// abi.encode(address(MAINNET_DEPLOYER))));
//         address routerEscrow = _deploy(
//             keccak256(abi.encodePacked(MAINNET_SALT, "escrow2")),
//             abi.encodePacked(type(Escrow).creationCode, abi.encode(address(MAINNET_DEPLOYER)))
//         );
//         address root = _deploy(
//             MAINNET_SALT,
//             abi.encodePacked(type(Root).creationCode, abi.encode(address(escrow), DELAY, MAINNET_DEPLOYER))
//         );
//         address restrictionManager = _deploy(
//             MAINNET_SALT,
//             abi.encodePacked(type(RestrictionManager).creationCode, abi.encode(address(root), MAINNET_DEPLOYER))
//         );
//         address trancheFactory = _deploy(
//             MAINNET_SALT,
//             abi.encodePacked(type(TrancheFactory).creationCode, abi.encode(address(root), MAINNET_DEPLOYER))
//         );
//         address transferProxyFactory = _deploy(
//             MAINNET_SALT,
//             abi.encodePacked(type(TransferProxyFactory).creationCode, abi.encode(address(root), MAINNET_DEPLOYER))
//         );

//         // Check the addresses remain fixed
//         assertEq(escrow, 0x0000000005F458Fd6ba9EEb5f365D83b7dA913dD, "DeterminismTest/escrow-address-mismatch");
//         assertEq(
//             routerEscrow, 0x0F1b890fC6774Ef9b14e99de16302E24A6e7B4F7,
// "DeterminismTest/router-escrow-address-mismatch"
//         );
//         assertEq(root, 0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC, "DeterminismTest/root-address-mismatch");
//         assertEq(
//             restrictionManager,
//             0x4737C3f62Cc265e786b280153fC666cEA2fBc0c0,
//             "DeterminismTest/restriction-manager-address-mismatch"
//         );
//         assertEq(
//             trancheFactory,
//             0xFa072fB96F737bdBCEa28c921d43c34d3a4Dbb6C,
//             "DeterminismTest/tranche-factory-address-mismatch"
//         );
//         assertEq(
//             transferProxyFactory,
//             0xbe55eBC29344a26550E07EF59aeF791fA3b2A817,
//             "DeterminismTest/transfer-proxy-factory-address-mismatch"
//         );

//         // Check the bytecode of any of the deterministically deployed contracts has not been modified
//         assertEq(
//             keccak256(escrow.code),
//             0x4cbd7efe2319295d7c29c38569ab8ff94d1dce284d8f678753e3c934427f889d,
//             "DeterminismTest/escrow-bytecode-mismatch"
//         );
//         assertEq(
//             keccak256(routerEscrow.code),
//             0x4cbd7efe2319295d7c29c38569ab8ff94d1dce284d8f678753e3c934427f889d,
//             "DeterminismTest/router-escrow-bytecode-mismatch"
//         );
//         assertEq(
//             keccak256(root.code),
//             0xe3b8893b70f2552e1919f152cdcf860187d2dd89387f0c9f6b6e3f19f530e741,
//             "DeterminismTest/root-bytecode-mismatch"
//         );
//         assertEq(
//             keccak256(restrictionManager.code),
//             0xd831f92a7a47bd72b65b00b9ad7dc3b417e2da5a7c90551f0480edead15497e1,
//             "DeterminismTest/restriction-manager-bytecode-mismatch"
//         );
//         assertEq(
//             keccak256(trancheFactory.code),
//             0xba57bbc9fd815f451d25952918142f10cea1c6d90d2fa0c94e9f856a318cf2a7,
//             "DeterminismTest/tranche-factory-bytecode-mismatch"
//         );
//         assertEq(
//             keccak256(transferProxyFactory.code),
//             0x625180e41eba3fd52bb06958a14cee7dc2b12123015a95f353fe00ca4425201d,
//             "DeterminismTest/transfer-proxy-factory-bytecode-mismatch"
//         );
//     }

//     /// @dev Deploy the contract using the CREATE2 Deployer Proxy (provided by anvil)
//     function _deploy(bytes32 salt, bytes memory creationCode) public returns (address) {
//         (bool success,) = address(CREATE2_DEPLOYER).call(abi.encodePacked(salt, creationCode));
//         require(success, "failed-deployment");
//         return _getAddress(salt, creationCode);
//     }

//     /// @dev Precompute a contract address that is deployed with the CREATE2Deployer
//     function _getAddress(bytes32 salt, bytes memory creationCode) internal pure returns (address) {
//         return address(
//             uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt,
// keccak256(creationCode)))))
//         );
//     }
// }
