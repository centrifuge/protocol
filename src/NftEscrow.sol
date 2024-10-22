// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {IERC6909, INftEscrow} from "src/interfaces/INftEscrow.sol";

contract NftEscrow is Auth, INftEscrow {
    /// A list of NFTs with an associated element.
    mapping(uint160 nftId => uint256 elementId) public associations;

    constructor(address owner) Auth(owner) {}

    /// @inheritdoc INftEscrow
    function lock(IERC6909 source, uint256 tokenId, address from) external auth returns (uint160) {
        uint160 nftId = computeNftId(source, tokenId);

        require(source.balanceOf(address(this), tokenId) == 0, AlreadyLocked());

        bool ok = source.transferFrom(from, address(this), tokenId, 10 ** source.decimals(tokenId));
        require(ok, CanNotBeTransferred());

        emit Locked(source, tokenId);

        return nftId;
    }

    /// @inheritdoc INftEscrow
    function unlock(IERC6909 source, uint256 tokenId, address to) external auth {
        bool ok = source.transferFrom(address(this), to, tokenId, 10 ** source.decimals(tokenId));
        require(ok, CanNotBeTransferred());

        emit Unlocked(source, tokenId);
    }

    /// @inheritdoc INftEscrow
    function attach(IERC6909 source, uint256 tokenId, uint256 elementId) public auth returns (uint160) {
        uint160 nftId = computeNftId(source, tokenId);

        require(elementId != 0, InvalidElement());
        require(associations[nftId] == 0, AlreadyAttached());
        require(source.balanceOf(address(this), tokenId) > 0, NotLocked());

        associations[nftId] = elementId;

        emit Attached(nftId, elementId);

        return nftId;
    }

    /// @inheritdoc INftEscrow
    function detach(uint160 nftId) public auth {
        uint256 elementId = associations[nftId];
        require(elementId != 0, NotAttached());

        delete associations[nftId];

        emit Detached(nftId, elementId);
    }

    /// @inheritdoc INftEscrow
    function computeNftId(IERC6909 source, uint256 tokenId) public pure returns (uint160) {
        return uint160(uint256(keccak256(abi.encode(source, tokenId))));
    }
}
