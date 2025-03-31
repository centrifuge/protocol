// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Root} from "src/common/Root.sol";

import {TrancheFactory} from "src/vaults/factories/TrancheFactory.sol";
import {Tranche} from "src/vaults/token/Tranche.sol";
import {Escrow} from "src/vaults/Escrow.sol";
import {VaultKind} from "src/vaults/BaseVaults.sol";

import {BaseTest} from "test/vaults/BaseTest.sol";
import "forge-std/Test.sol";

interface PoolManagerLike {
    function getTranche(uint64 poolId, bytes16 trancheId) external view returns (address);
}

contract FactoryTest is Test {
    uint256 mainnetFork;
    uint256 polygonFork;
    address root;

    function setUp() public {
        if (vm.envOr("FORK_TESTS", false)) {
            mainnetFork = vm.createFork(vm.rpcUrl("ethereum-mainnet"));
            polygonFork = vm.createFork(vm.rpcUrl("polygon-mainnet"));
        }

        root = address(new Root(48 hours, address(this)));
    }

    function testTrancheFactoryIsDeterministicAcrossChains(uint64 poolId, bytes16 trancheId) public {
        if (vm.envOr("FORK_TESTS", false)) {
            vm.setEnv("DEPLOYMENT_SALT", "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563");
            vm.selectFork(mainnetFork);
            BaseTest testSetup1 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup1.setUp();
            testSetup1.deployVault(
                VaultKind.Async,
                poolId,
                18,
                testSetup1.restrictionManager(),
                "",
                "",
                trancheId,
                address(testSetup1.erc20()),
                0,
                0
            );
            address tranche1 = PoolManagerLike(address(testSetup1.poolManager())).getTranche(poolId, trancheId);
            address root1 = address(testSetup1.root());

            vm.selectFork(polygonFork);
            BaseTest testSetup2 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup2.setUp();
            testSetup2.deployVault(
                VaultKind.Async,
                poolId,
                18,
                testSetup2.restrictionManager(),
                "",
                "",
                trancheId,
                address(testSetup2.erc20()),
                0,
                0
            );
            address tranche2 = PoolManagerLike(address(testSetup2.poolManager())).getTranche(poolId, trancheId);
            address root2 = address(testSetup2.root());

            assertEq(address(root1), address(root2));
            assertEq(tranche1, tranche2);
        }
    }

    function testTrancheFactoryShouldBeDeterministic(bytes32 salt) public {
        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(
                                abi.encodePacked(
                                    type(TrancheFactory).creationCode, abi.encode(root), abi.encode(address(this))
                                )
                            )
                        )
                    )
                )
            )
        );
        TrancheFactory trancheFactory = new TrancheFactory{salt: salt}(root, address(this));
        assertEq(address(trancheFactory), predictedAddress);
    }

    function testTrancheShouldBeDeterministic(
        address asyncManager,
        address poolManager,
        string memory name,
        string memory symbol,
        bytes32 factorySalt,
        bytes32 tokenSalt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 0, 18));
        TrancheFactory trancheFactory = new TrancheFactory{salt: factorySalt}(root, address(this));

        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(trancheFactory),
                            tokenSalt,
                            keccak256(abi.encodePacked(type(Tranche).creationCode, abi.encode(decimals)))
                        )
                    )
                )
            )
        );

        address[] memory trancheWards = new address[](2);
        trancheWards[0] = address(asyncManager);
        trancheWards[1] = address(poolManager);

        address token = trancheFactory.newTranche(name, symbol, decimals, tokenSalt, trancheWards);

        assertEq(address(token), predictedAddress);
        assertEq(trancheFactory.getAddress(decimals, tokenSalt), address(token));
    }

    function testDeployingDeterministicAddressTwiceReverts(
        bytes32 salt,
        address asyncManager,
        address poolManager,
        string memory name,
        string memory symbol,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 0, 18));
        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            salt,
                            keccak256(
                                abi.encodePacked(
                                    type(TrancheFactory).creationCode, abi.encode(root), abi.encode(address(this))
                                )
                            )
                        )
                    )
                )
            )
        );

        address[] memory trancheWards = new address[](2);
        trancheWards[0] = address(asyncManager);
        trancheWards[1] = address(poolManager);

        TrancheFactory trancheFactory = new TrancheFactory{salt: salt}(root, address(this));
        assertEq(address(trancheFactory), predictedAddress);

        trancheFactory.newTranche(name, symbol, decimals, bytes32(0), trancheWards);
        vm.expectRevert();
        trancheFactory.newTranche(name, symbol, decimals, bytes32(0), trancheWards);
    }

    function _stringToBytes32(string memory source) internal pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }
}
