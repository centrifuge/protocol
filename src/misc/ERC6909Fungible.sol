// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

import {Auth} from "src/misc/Auth.sol";
import {ERC6909} from "src/misc/ERC6909.sol";
import {IERC6909Fungible} from "src/misc/interfaces/IERC6909.sol";

contract ERC6909Fungible is IERC6909Fungible, ERC6909, Auth {
    constructor(address _owner) Auth(_owner) {}

    /// @inheritdoc IERC6909Fungible
    function mint(address owner, uint256 tokenId, uint256 amount) external auth {
        _mint(owner, tokenId, amount);
    }

    /// @inheritdoc IERC6909Fungible
    function burn(address owner, uint256 tokenId, uint256 amount) external auth {
        _burn(owner, tokenId, amount);
    }

    /// @inheritdoc IERC6909Fungible
    function authTransferFrom(address sender, address receiver, uint256 tokenId, uint256 amount)
        external
        auth
        returns (bool)
    {
        return _transfer(sender, receiver, tokenId, amount);
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override(ERC6909, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
