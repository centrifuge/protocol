// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Tranche} from "src/vaults/token/Tranche.sol";
import {ITrancheFactory} from "src/vaults/interfaces/factories/ITrancheFactory.sol";
import {Auth} from "src/misc/Auth.sol";

/// @title  Tranche Token Factory
/// @dev    Utility for deploying new tranche token contracts
///         Ensures the addresses are deployed at a deterministic address
///         based on the pool id and tranche id.
contract TrancheFactory is Auth, ITrancheFactory {
    address public immutable root;

    constructor(address _root, address deployer) Auth(deployer) {
        root = _root;
    }

    /// @inheritdoc ITrancheFactory
    function newTranche(
        string memory name,
        string memory symbol,
        uint8 decimals,
        bytes32 salt,
        address[] calldata trancheWards
    ) public auth returns (address) {
        Tranche token = new Tranche{salt: salt}(decimals);

        token.file("name", name);
        token.file("symbol", symbol);

        token.rely(root);
        uint256 wardsCount = trancheWards.length;
        for (uint256 i; i < wardsCount; i++) {
            token.rely(trancheWards[i]);
        }
        token.deny(address(this));

        return address(token);
    }

    /// @inheritdoc ITrancheFactory
    function getAddress(uint8 decimals, bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(type(Tranche).creationCode, abi.encode(decimals)))
            )
        );

        return address(uint160(uint256(hash)));
    }
}
