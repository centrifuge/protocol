// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {IERC6909, INftEscrow} from "src/interfaces/INftEscrow.sol";

contract NftEscrow is Auth, INftEscrow {
    constructor(address owner) Auth(owner) {}

    /// @inheritdoc INftEscrow
    function lock(IERC6909 source, uint256 tokenId, address from) external auth {
        require(source.balanceOf(address(this), tokenId) == 0, AlreadyLocked());

        bool ok = source.transferFrom(from, address(this), tokenId, 1);
        require(ok, CanNotBeTransferred());

        emit Locked(source, tokenId);
    }

    /// @inheritdoc INftEscrow
    function unlock(IERC6909 source, uint256 tokenId, address to) external auth {
        require(source.balanceOf(address(this), tokenId) == 1, NotLocked());

        bool ok = source.transferFrom(address(this), to, tokenId, 1);
        require(ok, CanNotBeTransferred());

        emit Unlocked(source, tokenId);
    }

    /// @inheritdoc INftEscrow
    function computeNftId(IERC6909 source, uint256 tokenId) public pure returns (uint160) {
        return uint160(uint256(keccak256(abi.encodePacked(source, tokenId))));
    }
}
