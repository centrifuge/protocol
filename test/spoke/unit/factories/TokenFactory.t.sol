// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {Root} from "../../../../src/common/Root.sol";

import {ShareToken} from "../../../../src/spoke/ShareToken.sol";
import {IShareToken} from "../../../../src/spoke/interfaces/IShareToken.sol";
import {TokenFactory} from "../../../../src/spoke/factories/TokenFactory.sol";

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
