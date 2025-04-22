// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {ShareToken} from "src/vaults/token/ShareToken.sol";
import {ITokenFactory} from "src/vaults/interfaces/factories/ITokenFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

/// @title  Share Token Factory
/// @dev    Utility for deploying new share class token contracts
///         Ensures the addresses are deployed at a deterministic address
///         based on the pool id and share class id.
contract TokenFactory is Auth, ITokenFactory {
    address public immutable root;

    constructor(address _root, address deployer) Auth(deployer) {
        root = _root;
    }

    /// @inheritdoc ITokenFactory
    function newToken(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address[] calldata tokenWards
    ) public auth returns (IShareToken) {
        ShareToken token = new ShareToken{salt: salt}(decimals);

        token.file("name", name);
        token.file("symbol", symbol);

        token.rely(root);
        uint256 wardsCount = tokenWards.length;
        for (uint256 i; i < wardsCount; i++) {
            token.rely(tokenWards[i]);
        }
        token.deny(address(this));

        return token;
    }

    /// @inheritdoc ITokenFactory
    function getAddress(uint8 decimals, bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(ShareToken).creationCode, abi.encode(decimals)))
            )
        );

        return address(uint160(uint256(hash)));
    }
}
