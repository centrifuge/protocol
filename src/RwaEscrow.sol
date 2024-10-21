// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

import {Auth} from "src/Auth.sol";
import {IERC6909} from "src/interfaces/Common.sol";

contract RwaEscrow is Auth {
    /// A list of RWAs with an associated element.
    mapping(uint160 rwaId => uint256 elementId) public associations;

    event Locked(IERC6909 source, uint256 tokenId, uint160 rwaId);
    event Unlocked(IERC6909 source, uint256 tokenId);
    event Attached(uint160 rwaId, uint256 elementId);
    event Detached(uint160 rwaId, uint256 elementId);

    constructor(address owner) Auth(owner) {}

    function lock(IERC6909 source, uint256 tokenId, address from) external auth returns (uint160) {
        uint160 rwaId = getRwaId(source, tokenId);

        require(source.balanceOf(address(this), tokenId) == 0, "RWA already in the escrow");

        bool ok = source.transferFrom(from, address(this), tokenId, 10 ** source.decimals(tokenId));
        require(ok, "Token could not be transfered");

        emit Locked(source, tokenId, rwaId);

        return rwaId;
    }

    function unlock(IERC6909 source, uint256 tokenId, address to) external auth {
        bool ok = source.transferFrom(address(this), to, tokenId, 10 ** source.decimals(tokenId));
        require(ok, "Token could not be transfered");

        emit Unlocked(source, tokenId);
    }

    function attach(IERC6909 source, uint256 tokenId, uint256 elementId) public auth returns (uint160) {
        uint160 rwaId = getRwaId(source, tokenId);

        require(elementId != 0, "Element Id not valid");
        require(associations[rwaId] == 0, "Element already attached");
        require(source.balanceOf(address(this), tokenId) > 0, "RWA was not locked");

        associations[rwaId] = elementId;

        emit Attached(rwaId, elementId);

        return rwaId;
    }

    function deattach(uint160 rwaId, uint256 elementId) public auth {
        require(associations[rwaId] != 0, "Element is not attached");

        delete associations[rwaId];

        emit Detached(rwaId, elementId);
    }

    /// @dev Returns a global identification of a RWA
    function getRwaId(IERC6909 source, uint256 tokenId) public pure returns (uint160) {
        return uint160(uint256(keccak256(abi.encode(source, tokenId))));
    }
}
