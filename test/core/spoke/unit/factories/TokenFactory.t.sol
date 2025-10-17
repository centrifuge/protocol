// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../../src/misc/interfaces/IAuth.sol";

import {ShareToken} from "../../../../../src/core/spoke/ShareToken.sol";
import {IShareToken} from "../../../../../src/core/spoke/interfaces/IShareToken.sol";
import {TokenFactory} from "../../../../../src/core/spoke/factories/TokenFactory.sol";
import {ITokenFactory} from "../../../../../src/core/spoke/factories/interfaces/ITokenFactory.sol";

import {Root} from "../../../../../src/admin/Root.sol";

import "forge-std/Test.sol";

interface SpokeLike {
    function getShare(uint64 poolId, bytes16 scId) external view returns (address);
}

contract FactoryTest is Test {
    address root = address(new Root(48 hours, address(this)));

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
        assertEq(IAuth(address(token)).wards(address(root)), 1);
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

contract TokenFactoryFileTest is Test {
    address root = address(new Root(48 hours, address(this)));
    TokenFactory tokenFactory = new TokenFactory(root, address(this));

    function testFileWards() public {
        address[] memory newWards = new address[](3);
        newWards[0] = makeAddr("ward1");
        newWards[1] = makeAddr("ward2");
        newWards[2] = makeAddr("ward3");

        vm.expectEmit(true, true, true, true);
        emit ITokenFactory.File("wards", newWards);

        tokenFactory.file("wards", newWards);

        assertEq(tokenFactory.tokenWards(0), newWards[0]);
        assertEq(tokenFactory.tokenWards(1), newWards[1]);
        assertEq(tokenFactory.tokenWards(2), newWards[2]);
    }

    function testFileWardsEmpty() public {
        address[] memory emptyWards = new address[](0);

        vm.expectEmit(true, true, true, true);
        emit ITokenFactory.File("wards", emptyWards);

        tokenFactory.file("wards", emptyWards);

        vm.expectRevert();
        tokenFactory.tokenWards(0);
    }

    function testFileUnrecognizedParam() public {
        address[] memory data = new address[](1);
        data[0] = address(1);

        vm.expectRevert(ITokenFactory.FileUnrecognizedParam.selector);
        tokenFactory.file("unknown", data);
    }

    function testFileNotAuthorized() public {
        address[] memory data = new address[](1);
        data[0] = address(1);

        vm.prank(makeAddr("notAuthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        tokenFactory.file("wards", data);
    }
}
