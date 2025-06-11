// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {Escrow} from "src/misc/Escrow.sol";

import {Root} from "src/common/Root.sol";

import {TokenFactory} from "src/spoke/factories/TokenFactory.sol";
import {ShareToken} from "src/spoke/ShareToken.sol";
import {VaultKind} from "src/spoke/interfaces/IVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {BaseTest} from "test/spoke/BaseTest.sol";
import "forge-std/Test.sol";

interface SpokeLike {
    function getShare(uint64 poolId, bytes16 scId) external view returns (address);
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

    function testTokenFactoryIsDeterministicAcrossChains(bytes16 scId) public {
        if (vm.envOr("FORK_TESTS", false)) {
            vm.setEnv("DEPLOYMENT_SALT", "0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563");
            vm.selectFork(mainnetFork);
            BaseTest testSetup1 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup1.setUp();
            testSetup1.deployVault(
                VaultKind.Async,
                18,
                testSetup1.fullRestrictionsHook(),
                bytes16(bytes("1")),
                address(testSetup1.erc20()),
                0,
                0
            );
            address token1 = SpokeLike(address(testSetup1.spoke())).getShare(testSetup1.POOL_A().raw(), scId);
            address root1 = address(testSetup1.root());

            vm.selectFork(polygonFork);
            BaseTest testSetup2 = new BaseTest{salt: keccak256(abi.encode(vm.envString("DEPLOYMENT_SALT")))}();
            testSetup2.setUp();
            testSetup2.deployVault(
                VaultKind.Async,
                18,
                testSetup2.fullRestrictionsHook(),
                bytes16(bytes("1")),
                address(testSetup2.erc20()),
                0,
                0
            );
            address token2 = SpokeLike(address(testSetup2.spoke())).getShare(testSetup2.POOL_A().raw(), scId);
            address root2 = address(testSetup2.root());

            assertEq(address(root1), address(root2));
            assertEq(token1, token2);
        }
    }

    function testShareShouldBeDeterministic(
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
                            keccak256(abi.encodePacked(type(ShareToken).creationCode, abi.encode(decimals)))
                        )
                    )
                )
            )
        );

        IShareToken token = tokenFactory.newToken(name, symbol, decimals, tokenSalt);

        assertEq(address(token), predictedAddress);
        assertEq(tokenFactory.getAddress(decimals, tokenSalt), address(token));
    }

    function testTokenWards(
        string memory name,
        string memory symbol,
        bytes32 factorySalt,
        bytes32 tokenSalt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 0, 18));
        TokenFactory tokenFactory = new TokenFactory{salt: factorySalt}(root, address(this));

        address[] memory tokenWards = new address[](2);
        tokenWards[0] = address(1);
        tokenWards[1] = address(2);

        tokenFactory.file("wards", tokenWards);

        IShareToken token = tokenFactory.newToken(name, symbol, decimals, tokenSalt);

        assertEq(IAuth(address(token)).wards(address(1)), 1);
        assertEq(IAuth(address(token)).wards(address(2)), 1);
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
