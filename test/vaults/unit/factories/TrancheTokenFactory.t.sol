// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {TokenFactory} from "src/vaults/factories/TokenFactory.sol";
import {CentrifugeToken} from "src/vaults/token/ShareToken.sol";
import {Root} from "src/common/Root.sol";
import {Escrow} from "src/vaults/Escrow.sol";
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

    function testTokenFactoryIsDeterministicAcrossChains(uint64 poolId, bytes16 trancheId) public {
        if (vm.envOr("FORK_TESTS", false)) {
            vm.setEnv("DEPLOYMENT_SALT", "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563");
            vm.selectFork(mainnetFork);
            BaseTest testSetup1 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup1.setUp();
            testSetup1.deployVault(
                poolId, 18, testSetup1.restrictionManager(), "", "", trancheId, address(testSetup1.erc20()), 0, 0
            );
            address tranche1 = PoolManagerLike(address(testSetup1.poolManager())).getTranche(poolId, trancheId);
            address root1 = address(testSetup1.root());

            vm.selectFork(polygonFork);
            BaseTest testSetup2 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup2.setUp();
            testSetup2.deployVault(
                poolId, 18, testSetup2.restrictionManager(), "", "", trancheId, address(testSetup2.erc20()), 0, 0
            );
            address tranche2 = PoolManagerLike(address(testSetup2.poolManager())).getTranche(poolId, trancheId);
            address root2 = address(testSetup2.root());

            assertEq(address(root1), address(root2));
            assertEq(tranche1, tranche2);
        }
    }

    function testTokenFactoryShouldBeDeterministic(bytes32 salt) public {
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
                                    type(TokenFactory).creationCode, abi.encode(root), abi.encode(address(this))
                                )
                            )
                        )
                    )
                )
            )
        );
        TokenFactory tokenFactory = new TokenFactory{salt: salt}(root, address(this));
        assertEq(address(tokenFactory), predictedAddress);
    }

    function testTrancheShouldBeDeterministic(
        address investmentManager,
        address poolManager,
        string memory name,
        string memory symbol,
        bytes32 factorySalt,
        bytes32 tokenSalt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 0, 18));
        TokenFactory tokenFactory = new TokenFactory{salt: factorySalt}(root, address(this));

        address predictedAddress = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(tokenFactory),
                            tokenSalt,
                            keccak256(abi.encodePacked(type(CentrifugeToken).creationCode, abi.encode(decimals)))
                        )
                    )
                )
            )
        );

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(investmentManager);
        tokenWards[1] = address(poolManager);

        address token = tokenFactory.newToken(name, symbol, decimals, tokenSalt, tokenWards);

        assertEq(address(token), predictedAddress);
        assertEq(tokenFactory.getAddress(decimals, tokenSalt), address(token));
    }

    function testDeployingDeterministicAddressTwiceReverts(
        bytes32 salt,
        address investmentManager,
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
                                    type(TokenFactory).creationCode, abi.encode(root), abi.encode(address(this))
                                )
                            )
                        )
                    )
                )
            )
        );

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(investmentManager);
        tokenWards[1] = address(poolManager);

        TokenFactory tokenFactory = new TokenFactory{salt: salt}(root, address(this));
        assertEq(address(tokenFactory), predictedAddress);

        tokenFactory.newToken(name, symbol, decimals, bytes32(0), tokenWards);
        vm.expectRevert();
        tokenFactory.newToken(name, symbol, decimals, bytes32(0), tokenWards);
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
